// Kizuna for iOS/iPadOS - low-latency audio output
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
//
// chiaki's Opus decoder hands us 10 ms chunks of int16 PCM (48 kHz stereo) on
// its audio thread. They go into a lock-free single-producer/single-consumer
// ring (implemented in the C shim: kz_audio_ring_*), which an AVAudioSourceNode
// drains on the real-time render thread as float.
//
// Latency is bounded the same way as Kizuna's Switch audout path:
//  - playback (re)starts only once ~30 ms are buffered (fade-in),
//  - writes that would push the backlog above ~60 ms are shed with a fade,
//  - an underrun fades out and re-primes instead of clicking.
// No gain or clipping is applied: the samples are converted 1:1 (x / 32768).

import AVFAudio
import AVFoundation
import Foundation

final class AudioOutput: @unchecked Sendable {
    /// Ring pointer read by the render block; swapped only while the engine is stopped.
    private final class RingBox: @unchecked Sendable {
        var ring: OpaquePointer?
    }

    private let engine = AVAudioEngine()
    private let box = RingBox()
    private let lock = NSLock()
    private let setupQueue = DispatchQueue(label: "ro.kizuna.audio.setup", qos: .userInitiated)
    private var sourceNode: AVAudioSourceNode?
    private var channels: UInt32 = 0
    private var sampleRate: UInt32 = 0
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    private let targetMs: UInt32 = 30
    private let maxMs: UInt32 = 60

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: nil) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: nil) { [weak self] _ in
            // Route change (headphones, AirPlay...): the engine stopped itself.
            self?.setupQueue.async { self?.restartEngine() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            self?.setupQueue.async { self?.rebuild() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        engine.stop()
        if let ring = box.ring {
            box.ring = nil
            kz_audio_ring_destroy(ring)
        }
    }

    // MARK: chiaki audio thread

    /// From chiaki's Opus decoder settings callback (once per stream, before frames).
    func configure(channels: UInt32, sampleRate: UInt32) {
        setupQueue.sync {
            lock.lock()
            let unchanged = channels == self.channels && sampleRate == self.sampleRate && box.ring != nil
            lock.unlock()
            if unchanged { return }
            lock.lock()
            self.channels = channels
            self.sampleRate = sampleRate
            lock.unlock()
            rebuild()
        }
    }

    /// Interleaved int16 PCM, `frames` samples per channel.
    func push(_ pcm: UnsafePointer<Int16>, frames: Int) {
        // Held during the (short) copy so rebuild()/stop() cannot free the ring
        // underneath us; the render thread never takes this lock.
        lock.lock()
        if let ring = box.ring {
            _ = kz_audio_ring_write(ring, pcm, frames)
        }
        lock.unlock()
    }

    // MARK: Control

    func stop() {
        setupQueue.sync {
            lock.lock()
            stopped = true
            lock.unlock()
            engine.stop()
            if let node = sourceNode {
                engine.detach(node)
                sourceNode = nil
            }
            lock.lock()
            let ring = box.ring
            box.ring = nil
            lock.unlock()
            if let ring {
                kz_audio_ring_destroy(ring)
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    func stats() -> KZAudioRingStats {
        var stats = KZAudioRingStats()
        lock.lock()
        kz_audio_ring_get_stats(box.ring, &stats)
        lock.unlock()
        return stats
    }

    // MARK: Engine (setupQueue)

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback without .mixWithOthers: the stream owns the audio route.
            try session.setCategory(.playback, mode: .default, options: [])
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            LogStore.shared.info("audio session error: \(error.localizedDescription)")
        }
    }

    private func rebuild() {
        lock.lock()
        let isStopped = stopped
        let channelCount = channels
        let rate = sampleRate
        lock.unlock()
        guard !isStopped, channelCount > 0, rate > 0 else { return }

        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        lock.lock()
        let oldRing = box.ring
        box.ring = kz_audio_ring_create(min(channelCount, 2), rate, targetMs, maxMs)
        lock.unlock()
        if let oldRing {
            kz_audio_ring_destroy(oldRing)
        }

        configureSession()

        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2) else {
            LogStore.shared.info("audio: unsupported format \(rate) Hz")
            return
        }
        let ringBox = box
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            kz_audio_ring_read(ringBox.ring, left, right ?? left, Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        engine.prepare()
        do {
            try engine.start()
            let session = AVAudioSession.sharedInstance()
            LogStore.shared.info(String(format: "audio: %u ch @ %u Hz, IO buffer %.1f ms, output latency %.1f ms",
                                        channelCount, rate, session.ioBufferDuration * 1000, session.outputLatency * 1000))
        } catch {
            LogStore.shared.info("audio engine start failed: \(error.localizedDescription)")
        }
    }

    private func restartEngine() {
        lock.lock()
        let isStopped = stopped
        let ring = box.ring
        lock.unlock()
        guard !isStopped, sourceNode != nil else { return }
        kz_audio_ring_flush(ring)
        configureSession()
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            setupQueue.async { [weak self] in
                self?.restartEngine()
            }
        }
    }
}
