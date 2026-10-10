// Kizuna for iOS/iPadOS - Swift side of the C shim (library, logs, discovery, registration)
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors
//
// Threading: every C callback arrives on a chiaki / shim worker thread. This file
// copies the data out immediately (pointers are only valid during the call) and
// hops to the main queue before touching anything observable.

import Foundation
import Security
import os

// MARK: - Library bootstrap + log

enum KizunaCoreBridge {
    private static let bootstrapResult: Int32 = {
        kz_core_set_log_mask(UInt32(KZ_LOG_ERROR | KZ_LOG_WARNING | KZ_LOG_INFO))
        kz_core_set_log_callback({ level, message, _ in
            guard let message else { return }
            LogStore.shared.append(level: level, message: String(cString: message))
        }, nil)
        return kz_core_init()
    }()

    /// Idempotent; call before any other shim function.
    @discardableResult
    static func bootstrap() -> Int32 {
        bootstrapResult
    }

    static func errorString(_ code: Int32) -> String {
        guard let cString = kz_error_string(code) else { return "error \(code)" }
        return String(cString: cString)
    }

    static var version: String {
        guard let cString = kz_core_version() else { return "?" }
        return String(cString: cString)
    }

    /// "0000000700410080" + 32 random hex chars, as the official client uses.
    static func generateClientDUID() -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        let err = kz_generate_client_duid(&buffer, buffer.count)
        if err == KZ_OK {
            let value = String(cString: buffer)
            if value.count == 48 { return value }
        }
        // Fallback with the same format if the C helper is unavailable.
        var random = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        return "0000000700410080" + random.map { String(format: "%02x", $0) }.joined()
    }
}

/// Last few hundred log lines (chiaki + Kizuna), shown in Settings for support.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 400
    private let logger = Logger(subsystem: "ro.kizuna.remoteplay", category: "core")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func append(level: Int32, message: String) {
        let tag: String
        if level == KZ_LOG_ERROR {
            tag = "E"
            logger.error("\(message, privacy: .public)")
        } else if level == KZ_LOG_WARNING {
            tag = "W"
            logger.warning("\(message, privacy: .public)")
        } else {
            tag = "I"
            logger.info("\(message, privacy: .public)")
        }
        lock.lock()
        let line = "\(formatter.string(from: Date())) [\(tag)] \(message)"
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        lock.unlock()
    }

    func info(_ message: String) {
        append(level: KZ_LOG_INFO, message: "[Kizuna] " + message)
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Discovery

enum ConsoleState: String, Codable {
    case ready
    case standby
    case offline
    case unknown
}

struct DiscoveredConsole: Identifiable, Hashable {
    let hostID: String
    let name: String
    let address: String
    let isPS5: Bool
    let target: Int32
    let state: ConsoleState
    let systemVersion: String
    let runningApp: String
    var seenAt: Date

    var id: String { hostID.isEmpty ? address : hostID.uppercased() }
}

/// Wraps KZDiscovery: a UDP socket + receive thread in the shim, plus unicast
/// sweeps of the local /24 (no multicast entitlement needed).
final class DiscoveryService: @unchecked Sendable {
    /// Called on the main queue for every SRCH answer.
    var onHost: ((DiscoveredConsole) -> Void)?

    private var handle: OpaquePointer?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ro.kizuna.discovery", qos: .utility)

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if handle != nil { return true }
        KizunaCoreBridge.bootstrap()
        var err: Int32 = 0
        let user = Unmanaged.passUnretained(self).toOpaque()
        handle = kz_discovery_create({ hostPointer, user in
            guard let hostPointer, let user else { return }
            let service = Unmanaged<DiscoveryService>.fromOpaque(user).takeUnretainedValue()
            let host = hostPointer.pointee
            let state: ConsoleState
            if host.state == KZ_HOST_STATE_READY {
                state = .ready
            } else if host.state == KZ_HOST_STATE_STANDBY {
                state = .standby
            } else {
                state = .unknown
            }
            let console = DiscoveredConsole(
                hostID: String(cString: host.host_id),
                name: String(cString: host.name),
                address: String(cString: host.address),
                isPS5: host.is_ps5,
                target: host.target,
                state: state,
                systemVersion: String(cString: host.system_version),
                runningApp: String(cString: host.running_app_name),
                seenAt: Date())
            DispatchQueue.main.async {
                service.onHost?(console)
            }
        }, user, &err)
        if handle == nil {
            LogStore.shared.info("discovery could not start: \(KizunaCoreBridge.errorString(err))")
        }
        return handle != nil
    }

    /// Unicast SRCH to every host of each local /24 (both PS5 and PS4 ports).
    func sweep() {
        queue.async { [self] in
            lock.lock()
            if let handle {
                _ = kz_discovery_sweep(handle)
            }
            lock.unlock()
        }
    }

    /// Direct probe of a known address (manual IP or last known address).
    func probe(_ address: String) {
        guard !address.isEmpty else { return }
        queue.async { [self] in
            lock.lock()
            if let handle {
                _ = kz_discovery_probe(handle, address)
            }
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        let current = handle
        handle = nil
        lock.unlock()
        if let current {
            kz_discovery_destroy(current)
        }
    }

    /// Fire-and-forget WAKEUP packet (regist key = the 16 raw bytes from pairing).
    static func wake(address: String, registKey: Data, ps5: Bool) -> Int32 {
        guard registKey.count >= Int(KZ_REGIST_KEY_SIZE) else { return KZ_ERR_INVALID_DATA }
        return registKey.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return KZ_ERR_INVALID_DATA }
            return kz_wakeup(address, base, ps5)
        }
    }
}

// MARK: - Registration

struct RegisteredHostInfo {
    let target: Int32
    let registKey: Data      // 16 bytes
    let rpKey: Data          // 16 bytes
    let rpKeyType: UInt32
    let serverMAC: Data      // 6 bytes
    let nickname: String
    let consoleAddress: String

    var hostID: String {
        serverMAC.map { String(format: "%02X", $0) }.joined()
    }
}

private let kzRegistCallback: KZRegistCallback = { status, result, message, user in
    guard let user else { return }
    let job = Unmanaged<RegistrationJob>.fromOpaque(user).takeUnretainedValue()
    let outcome: RegistrationJob.Outcome
    if status == KZ_REGIST_SUCCESS, let result {
        let r = result.pointee
        let info = RegisteredHostInfo(
            target: r.target,
            registKey: Data(bytes: r.regist_key, count: Int(KZ_REGIST_KEY_SIZE)),
            rpKey: Data(bytes: r.rp_key, count: Int(KZ_RP_KEY_SIZE)),
            rpKeyType: r.rp_key_type,
            serverMAC: Data(bytes: r.server_mac, count: Int(KZ_SERVER_MAC_SIZE)),
            nickname: r.server_nickname.map { String(cString: $0) } ?? "",
            consoleAddress: r.console_address.map { String(cString: $0) } ?? "")
        outcome = .success(info)
    } else if status == KZ_REGIST_CANCELED {
        outcome = .canceled
    } else {
        outcome = .failed(message.map { String(cString: $0) } ?? "")
    }
    job.finish(outcome)
}

private let kzRegistProgress: KZProgressCallback = { stage, user in
    guard let user else { return }
    let job = Unmanaged<RegistrationJob>.fromOpaque(user).takeUnretainedValue()
    job.reportProgress(stage)
}

/// One registration attempt (PIN on the LAN, or PIN-less through PSN).
/// The job keeps itself alive until its completion has run.
final class RegistrationJob: @unchecked Sendable {
    enum Outcome {
        case success(RegisteredHostInfo)
        case failed(String)
        case canceled
    }

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var completion: ((Outcome) -> Void)?
    private var progress: ((Int32) -> Void)?
    private var keepAlive: RegistrationJob?

    private init(progress: ((Int32) -> Void)?, completion: @escaping (Outcome) -> Void) {
        self.progress = progress
        self.completion = completion
    }

    /// Classic pairing with the 8-digit PIN from Settings > System > Remote Play.
    static func startPIN(address: String, target: Int32, accountID: String, pin: UInt32,
                         completion: @escaping (Outcome) -> Void) -> RegistrationJob? {
        KizunaCoreBridge.bootstrap()
        let job = RegistrationJob(progress: nil, completion: completion)
        let user = Unmanaged.passUnretained(job).toOpaque()
        var err: Int32 = 0
        job.lock.lock()
        job.keepAlive = job
        job.handle = kz_regist_start_pin(address, target, accountID, pin, kzRegistCallback, user, &err)
        let started = job.handle != nil
        if !started { job.keepAlive = nil }
        job.lock.unlock()
        if !started {
            completion(.failed(KizunaCoreBridge.errorString(err)))
            return nil
        }
        return job
    }

    /// PIN-less pairing over PSN (holepunch + RUDP), like the official app.
    static func startPSN(accessToken: String, consoleDUID: String, ps5: Bool, accountID: String,
                         progress: @escaping (Int32) -> Void,
                         completion: @escaping (Outcome) -> Void) -> RegistrationJob? {
        KizunaCoreBridge.bootstrap()
        let job = RegistrationJob(progress: progress, completion: completion)
        let user = Unmanaged.passUnretained(job).toOpaque()
        var err: Int32 = 0
        job.lock.lock()
        job.keepAlive = job
        job.handle = kz_regist_start_psn(accessToken, consoleDUID, ps5, accountID,
                                         kzRegistProgress, kzRegistCallback, user, &err)
        let started = job.handle != nil
        if !started { job.keepAlive = nil }
        job.lock.unlock()
        if !started {
            completion(.failed(KizunaCoreBridge.errorString(err)))
            return nil
        }
        return job
    }

    func cancel() {
        lock.lock()
        let current = handle
        lock.unlock()
        if let current {
            kz_regist_cancel(current)
        }
    }

    fileprivate func reportProgress(_ stage: Int32) {
        DispatchQueue.main.async { [self] in
            progress?(stage)
        }
    }

    /// Worker thread -> main queue. The C handle is destroyed on a background
    /// queue afterwards (kz_regist_destroy joins the worker).
    fileprivate func finish(_ outcome: Outcome) {
        DispatchQueue.main.async { [self] in
            let done = completion
            completion = nil
            progress = nil
            done?(outcome)
            lock.lock()
            let current = handle
            handle = nil
            lock.unlock()
            DispatchQueue.global(qos: .utility).async { [self] in
                if let current {
                    kz_regist_destroy(current)
                }
                lock.lock()
                keepAlive = nil
                lock.unlock()
            }
        }
    }
}
