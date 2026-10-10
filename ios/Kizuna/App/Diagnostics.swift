// Kizuna for iOS/iPadOS - diagnostics log ("Jurnal de diagnostic")
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
//
// Same format as the Switch version: one JSON Lines file per stream session in
// Application Support/diagnostics (last 20 kept). It records how the stream
// performed, never who streamed: no PSN identifiers, tokens, console names, host
// ids or IP addresses. Nothing leaves the device unless the user exports it from
// Settings (share sheet).

import Foundation
import Network
import UIKit

final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    struct Summary {
        let minutes: Double
        let score: Int
        let framesLost: UInt64
        let audioUnderruns: UInt64
    }

    private static let enabledKey = "kizuna.diagnostics.enabled"
    private static let keepSessions = 20

    private let queue = DispatchQueue(label: "ro.kizuna.diagnostics", qos: .utility)
    private let pathMonitor = NWPathMonitor()
    private var currentPath: NWPath?

    // Guarded by `queue`.
    private var handle: FileHandle?
    private var start = Date()
    private var samples = 0
    private var requestedFps = 0
    private var sumMbps = 0.0, sumLoss = 0.0, sumFps = 0.0, sumProc = 0.0, maxProc = 0.0, sumRtt = 0.0
    private var rttSamples = 0
    private var framesLost: UInt64 = 0
    private var audioUnderruns: UInt64 = 0
    private var quitReason: Int32 = -1

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.queue.async { self?.currentPath = path }
        }
        pathMonitor.start(queue: queue)
    }

    // MARK: Settings

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("diagnostics", isDirectory: true)
    }

    func sessionFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Session lifecycle (main thread callers)

    func begin(isPS5: Bool, viaPSN: Bool, resolution: Int, fps: Int, bitrateKbps: Int, hevc: Bool) {
        guard enabled else { return }
        let device = Self.deviceModel()
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let os = UIDevice.current.systemVersion
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        queue.async { [self] in
            closeLocked()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = directory.appendingPathComponent("session-\(formatter.string(from: Date())).jsonl")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            start = Date()
            samples = 0
            requestedFps = fps
            sumMbps = 0; sumLoss = 0; sumFps = 0; sumProc = 0; maxProc = 0; sumRtt = 0
            rttSamples = 0
            framesLost = 0
            audioUnderruns = 0
            quitReason = -1
            writeLocked([
                "t": "start", "v": 1, "app": "Kizuna \(version)", "platform": "ios",
                "device": device, "idiom": idiom, "os": os,
                "net": netType(), "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "console": isPS5 ? "PS5" : "PS4", "route": viaPSN ? "remote" : "local",
                "time": Int(Date().timeIntervalSince1970),
            ])
            writeLocked([
                "t": "profile", "req_res": resolution, "req_fps": fps, "req_kbps": bitrateKbps,
                "req_hevc": hevc, "hw_decoder": true, "renderer": "AVSampleBufferDisplayLayer",
            ])
        }
    }

    /// Once per second from StreamSession.refreshStats().
    func sample(seconds: Int, mbps: Double, loss: Double, fps: Double, processingMs: Double, rttMs: UInt32,
                framesLost lost: UInt64, framesRecovered: UInt64, videoDropped: UInt64, rendererFailures: UInt64,
                audioBufferedMs: UInt32, audioUnderruns under: UInt64) {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        queue.async { [self] in
            guard handle != nil else { return }
            writeLocked([
                "t": "s", "s": seconds, "mbps": round2(mbps), "loss": round2(loss * 100), "fps": round1(fps),
                "dec_ms": round2(processingMs), "rtt_ms": rttMs > 0 ? Int(rttMs) as Any : NSNull() as Any,
                "lost": lost, "rec": framesRecovered, "drops": videoDropped, "renderer_failures": rendererFailures,
                "au_buf_ms": Int(audioBufferedMs), "au_under": under, "net": netType(), "thermal": thermal,
            ])
            samples += 1
            sumMbps += mbps
            sumLoss += loss * 100
            sumFps += fps
            sumProc += processingMs
            maxProc = max(maxProc, processingMs)
            if rttMs > 0 {
                sumRtt += Double(rttMs)
                rttSamples += 1
            }
            framesLost = lost
            audioUnderruns = under
        }
    }

    func quit(code: Int32, text: String) {
        queue.async { [self] in
            guard handle != nil else { return }
            quitReason = code
            writeLocked(["t": "quit", "reason": Int(code), "text": text])
        }
    }

    /// Writes the summary line and closes the file. Returns the summary for long sessions.
    @discardableResult
    func end() -> Summary? {
        queue.sync { () -> Summary? in
            guard handle != nil else { return nil }
            let minutes = Date().timeIntervalSince(start) / 60
            let n = Double(max(samples, 1))
            let avgFps = sumFps / n
            // Share of the requested frame rate actually shown, minus 5 points per lost
            // frame per minute and 2 per audio underrun per minute (same as the Switch).
            var score = requestedFps > 0 ? 100 * min(1, avgFps / Double(requestedFps)) : 0
            if minutes > 0.05 {
                score -= 5 * Double(framesLost) / minutes
                score -= 2 * Double(audioUnderruns) / minutes
            }
            let finalScore = Int(max(0, min(100, score)).rounded())
            writeLocked([
                "t": "end", "minutes": round1(minutes), "samples": samples, "avg_mbps": round2(sumMbps / n),
                "avg_loss": round2(sumLoss / n), "avg_fps": round1(avgFps), "req_fps": requestedFps,
                "avg_dec_ms": round2(sumProc / n), "max_dec_ms": round2(maxProc),
                "avg_rtt_ms": rttSamples > 0 ? round1(sumRtt / Double(rttSamples)) as Any : NSNull() as Any,
                "frames_lost": framesLost, "audio_underruns": audioUnderruns,
                "quit_reason": Int(quitReason), "score": finalScore,
            ])
            let summary = samples >= 30
                ? Summary(minutes: minutes, score: finalScore, framesLost: framesLost, audioUnderruns: audioUnderruns)
                : nil
            closeLocked()
            pruneLocked()
            return summary
        }
    }

    // MARK: Export

    /// Writes every stored session into one file for the share sheet.
    func exportFile() -> URL? {
        queue.sync { () -> URL? in
            let files = sessionFiles()
            guard !files.isEmpty else { return nil }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            var out = Data()
            out.append(Self.line(["t": "export", "format": "kizuna-diagnostics", "v": 1,
                                  "app": "Kizuna \(version)", "platform": "ios", "sessions": files.count]))
            for file in files {
                out.append(Self.line(["t": "file", "name": file.lastPathComponent]))
                if let data = try? Data(contentsOf: file) { out.append(data) }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("kizuna-diagnostics.jsonl")
            try? out.write(to: url, options: .atomic)
            return url
        }
    }

    func clearAll() {
        queue.sync {
            closeLocked()
            for file in sessionFiles() { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: Helpers (queue)

    private func writeLocked(_ object: [String: Any]) {
        handle?.write(Self.line(object))
    }

    private func closeLocked() {
        try? handle?.close()
        handle = nil
    }

    private func pruneLocked() {
        var files = sessionFiles()
        while files.count > Self.keepSessions {
            try? FileManager.default.removeItem(at: files.removeFirst())
        }
    }

    private func netType() -> String {
        guard let path = currentPath, path.status == .satisfied else { return "none" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.wiredEthernet) { return "lan" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        return "other"
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
