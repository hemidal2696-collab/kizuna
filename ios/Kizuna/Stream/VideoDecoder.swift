// Kizuna for iOS/iPadOS - Annex-B -> CMSampleBuffer -> AVSampleBufferDisplayLayer
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
// NAL parsing / parameter-set handling adapted from TP Play
// ios/TPPlay/Platform/Streaming/VideoDecoder.swift (AGPL-3.0, Copyright (C)
// TP Play contributors); rendering uses AVSampleBufferDisplayLayer's
// AVSampleBufferVideoRenderer (iOS 17) instead of a VTDecompressionSession.
//
// chiaki delivers one access unit per callback in Annex-B form (start codes).
// The codec header (VPS/SPS/PPS or SPS/PPS) arrives once as a separate sample
// when the stream profile switches, IDR frames may or may not repeat it.
// We keep the latest parameter sets, (re)build the CMVideoFormatDescription
// when they change, convert start codes to 4-byte big-endian lengths, drop
// everything until the next keyframe after a problem, and display each frame
// immediately (kCMSampleAttachmentKey_DisplayImmediately, no timebase).

import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

final class VideoDecoder: @unchecked Sendable {
    struct Snapshot {
        var framesEnqueued: UInt64 = 0
        var framesDropped: UInt64 = 0
        var rendererFailures: UInt64 = 0
        var averageProcessingMs: Double = 0
    }

    /// Asks the console for a new IDR (called on the video queue, rate limited).
    var requestIDR: (() -> Void)?

    private let hevc: Bool
    private let queue = DispatchQueue(label: "ro.kizuna.video", qos: .userInteractive)
    private let lock = NSLock()

    // Guarded by `lock`.
    private var renderer: AVSampleBufferVideoRenderer?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Int: [UInt8]] = [:]
    private var needKeyframe = true
    private var pending = 0
    private var lastIDRRequest: CFAbsoluteTime = 0
    private var enqueued: UInt64 = 0
    private var dropped: UInt64 = 0
    private var failures: UInt64 = 0
    private var processingTotalMs: Double = 0
    private var processingSamples: Int = 0

    private static let maxPending = 6
    private static let idrInterval: CFAbsoluteTime = 0.35

    init(hevc: Bool) {
        self.hevc = hevc
    }

    // MARK: Display binding (main thread)

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        renderer = layer.sampleBufferRenderer
        needKeyframe = true
        lock.unlock()
        queue.async { [weak self] in
            self?.requestKeyframe(force: true)
        }
    }

    func detach() {
        lock.lock()
        let current = renderer
        renderer = nil
        needKeyframe = true
        lock.unlock()
        queue.async {
            current?.flush()
        }
    }

    /// After an interruption (background, route change...) the renderer fails;
    /// flush it and wait for a fresh IDR.
    func recover() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.renderer
            self.needKeyframe = true
            self.lock.unlock()
            current?.flush()
            self.requestKeyframe(force: true)
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(framesEnqueued: enqueued,
                        framesDropped: dropped,
                        rendererFailures: failures,
                        averageProcessingMs: processingSamples > 0 ? processingTotalMs / Double(processingSamples) : 0)
    }

    // MARK: Input (chiaki video thread)

    /// Returns false when the frame was not consumed so that chiaki reports a
    /// corrupt frame and the console sends a new IDR.
    func submit(_ data: UnsafePointer<UInt8>, count: Int) -> Bool {
        let started = CFAbsoluteTimeGetCurrent()
        let units = Self.nalRanges(data, count)
        guard !units.isEmpty else { return true }

        var hasSlice = false
        var isKeyframe = false
        var payload: [Range<Int>] = []
        payload.reserveCapacity(units.count)

        lock.lock()
        for unit in units {
            let type = nalType(data[unit.lowerBound])
            if isParameterSet(type) {
                let bytes = Array(UnsafeBufferPointer(start: data + unit.lowerBound, count: unit.count))
                if parameterSets[type] != bytes {
                    parameterSets[type] = bytes
                    formatDescription = nil   // rebuild with the new sets
                    needKeyframe = true
                }
                continue
            }
            if isAccessUnitDelimiter(type) { continue }
            if isSlice(type) {
                hasSlice = true
                if isKeyframeSlice(type) { isKeyframe = true }
            }
            payload.append(unit)
        }

        // Header-only sample (stream start / profile switch): configuration only.
        guard hasSlice else {
            lock.unlock()
            return true
        }

        // No display layer yet (view not on screen): drop, and resync on the
        // IDR that attach() requests.
        guard renderer != nil else {
            needKeyframe = true
            lock.unlock()
            return true
        }

        if needKeyframe && !isKeyframe {
            dropped &+= 1
            let ask = shouldAskForIDRLocked()
            lock.unlock()
            // Returning false makes chiaki request an IDR itself (rate limited).
            return !ask
        }

        if pending >= Self.maxPending {
            // The renderer is not keeping up: drop and resync on a keyframe
            // instead of letting latency grow.
            dropped &+= 1
            needKeyframe = true
            let ask = shouldAskForIDRLocked()
            lock.unlock()
            return !ask
        }

        if formatDescription == nil {
            formatDescription = makeFormatDescriptionLocked()
        }
        guard let format = formatDescription else {
            needKeyframe = true
            let ask = shouldAskForIDRLocked()
            lock.unlock()
            return !ask
        }
        lock.unlock()

        guard let sample = Self.makeSampleBuffer(data, payload, format: format, keyframe: isKeyframe) else {
            lock.lock()
            needKeyframe = true
            dropped &+= 1
            lock.unlock()
            return false
        }

        lock.lock()
        pending += 1
        if isKeyframe { needKeyframe = false }
        processingTotalMs += (CFAbsoluteTimeGetCurrent() - started) * 1000
        processingSamples += 1
        if processingSamples > 600 {
            processingTotalMs /= 2
            processingSamples /= 2
        }
        lock.unlock()

        queue.async { [weak self] in
            self?.enqueue(sample, keyframe: isKeyframe)
        }
        return true
    }

    // MARK: Video queue

    private func enqueue(_ sample: CMSampleBuffer, keyframe: Bool) {
        lock.lock()
        let current = renderer
        pending = max(0, pending - 1)
        lock.unlock()
        guard let current else { return }

        if current.status == .failed || current.requiresFlushToResumeDecoding {
            // Decoder session lost (background, media server reset...).
            if let error = current.error {
                LogStore.shared.info("video renderer failed: \(error.localizedDescription)")
            }
            current.flush()
            lock.lock()
            failures &+= 1
            needKeyframe = !keyframe
            lock.unlock()
            if !keyframe {
                requestKeyframe(force: true)
                return
            }
        }
        current.enqueue(sample)
        lock.lock()
        enqueued &+= 1
        lock.unlock()
    }

    private func requestKeyframe(force: Bool) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let allowed = force || now - lastIDRRequest > Self.idrInterval
        if allowed { lastIDRRequest = now }
        let callback = requestIDR
        lock.unlock()
        if allowed {
            callback?()
        }
    }

    private func shouldAskForIDRLocked() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastIDRRequest > Self.idrInterval {
            lastIDRRequest = now
            return true
        }
        return false
    }

    // MARK: NAL helpers

    private func nalType(_ header: UInt8) -> Int {
        hevc ? Int((header >> 1) & 0x3F) : Int(header & 0x1F)
    }

    private func isParameterSet(_ type: Int) -> Bool {
        hevc ? (32...34).contains(type) : (type == 7 || type == 8)
    }

    private func isAccessUnitDelimiter(_ type: Int) -> Bool {
        hevc ? type == 35 : type == 9
    }

    private func isSlice(_ type: Int) -> Bool {
        hevc ? (0...31).contains(type) : (1...5).contains(type)
    }

    private func isKeyframeSlice(_ type: Int) -> Bool {
        hevc ? (16...23).contains(type) : type == 5
    }

    /// Ranges of NAL payloads (start codes and trailing zero bytes removed).
    static func nalRanges(_ p: UnsafePointer<UInt8>, _ n: Int) -> [Range<Int>] {
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < n {
            if p[i] == 0 && p[i + 1] == 0 {
                if p[i + 2] == 1 {
                    starts.append((i, i + 3))
                    i += 3
                    continue
                }
                if i + 3 < n && p[i + 2] == 0 && p[i + 3] == 1 {
                    starts.append((i, i + 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(starts.count)
        for (index, start) in starts.enumerated() {
            var end = index + 1 < starts.count ? starts[index + 1].code : n
            while end > start.payload && p[end - 1] == 0 {
                end -= 1
            }
            if end > start.payload {
                ranges.append(start.payload..<end)
            }
        }
        return ranges
    }

    private func makeFormatDescriptionLocked() -> CMVideoFormatDescription? {
        let order = hevc ? [32, 33, 34] : [7, 8]
        let sets = order.compactMap { parameterSets[$0] }
        guard sets.count == order.count else { return nil }

        let buffers: [UnsafeMutablePointer<UInt8>] = sets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            pointer.initialize(from: set, count: set.count)
            return pointer
        }
        defer {
            for (index, pointer) in buffers.enumerated() {
                pointer.deinitialize(count: sets[index].count)
                pointer.deallocate()
            }
        }
        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        let sizes: [Int] = sets.map { $0.count }

        var description: CMFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: sets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &description)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: sets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &description)
        }
        if status != noErr {
            LogStore.shared.info("format description failed: \(status)")
            return nil
        }
        if let description {
            let dims = CMVideoFormatDescriptionGetDimensions(description)
            LogStore.shared.info("video format \(hevc ? "HEVC" : "H.264") \(dims.width)x\(dims.height)")
        }
        return description
    }

    private static func makeSampleBuffer(_ data: UnsafePointer<UInt8>, _ units: [Range<Int>],
                                         format: CMVideoFormatDescription, keyframe: Bool) -> CMSampleBuffer? {
        var total = 0
        for unit in units { total += 4 + unit.count }
        guard total > 0 else { return nil }

        var avcc = [UInt8]()
        avcc.reserveCapacity(total)
        for unit in units {
            let length = UInt32(unit.count)
            avcc.append(UInt8((length >> 24) & 0xFF))
            avcc.append(UInt8((length >> 16) & 0xFF))
            avcc.append(UInt8((length >> 8) & 0xFF))
            avcc.append(UInt8(length & 0xFF))
            avcc.append(contentsOf: UnsafeBufferPointer(start: data + unit.lowerBound, count: unit.count))
        }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { return nil }

        status = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                 offsetIntoDestination: 0, dataLength: raw.count)
        }
        guard status == noErr else { return nil }

        var sample: CMSampleBuffer?
        var sampleSize = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }

        setAttachment(sample, key: kCMSampleAttachmentKey_DisplayImmediately, value: kCFBooleanTrue)
        if !keyframe {
            setAttachment(sample, key: kCMSampleAttachmentKey_NotSync, value: kCFBooleanTrue)
        }
        return sample
    }

    private static func setAttachment(_ sample: CMSampleBuffer, key: CFString, value: CFBoolean) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(key).toOpaque(),
                             Unmanaged.passUnretained(value).toOpaque())
    }
}

// MARK: - SwiftUI host for the display layer

final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // layerClass guarantees the type.
        layer as! AVSampleBufferDisplayLayer
    }
}

struct StreamVideoView: UIViewRepresentable {
    let decoder: VideoDecoder

    final class Coordinator {
        let decoder: VideoDecoder
        init(decoder: VideoDecoder) { self.decoder = decoder }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(decoder: decoder)
    }

    func makeUIView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.displayLayer.videoGravity = .resizeAspect
        decoder.attach(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: VideoLayerView, context: Context) {}

    static func dismantleUIView(_ uiView: VideoLayerView, coordinator: Coordinator) {
        coordinator.decoder.detach()
    }
}
