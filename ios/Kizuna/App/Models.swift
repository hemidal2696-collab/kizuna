// Kizuna for iOS/iPadOS - persisted models
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors

import Foundation

/// A paired console. Non-secret metadata lives in UserDefaults; the keys
/// (ConsoleSecrets) live in the Keychain.
struct ConsoleRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var nickname: String = ""
    /// Last known LAN address (updated from discovery by MAC address).
    var address: String
    var isPS5: Bool
    /// MAC address as 12 upper-case hex chars (discovery "host-id").
    var hostID: String = ""
    /// PSN device id (64 hex) for away-from-home streaming, if known.
    var duid: String = ""
    var target: Int32
    var addedAt: Date = Date()

    var displayName: String { name.isEmpty ? (nickname.isEmpty ? "PlayStation" : nickname) : name }
    var platformLabel: String { isPS5 ? "PS5" : "PS4" }
    var canStreamRemotely: Bool { !duid.isEmpty }

    var keychainAccount: String { "console.\(id.uuidString)" }
}

struct ConsoleSecrets: Codable {
    var registKey: Data   // 16 bytes (ASCII hex, NUL padded) - also used for WAKEUP
    var rpKey: Data       // 16 bytes ("morning")
    var rpKeyType: UInt32
}

enum TouchControlsMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case always
    case never

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return L("touch.auto")
        case .always: return L("touch.always")
        case .never: return L("touch.never")
        }
    }
}

struct StreamSettings: Codable, Equatable {
    enum Preset: String, Codable, CaseIterable, Identifiable {
        case lowLatency
        case balanced
        case maxQuality
        case custom

        var id: String { rawValue }
        var title: String { L("preset.\(rawValue)") }
    }

    var preset: Preset = .balanced
    var resolution: Int = 1080          // 720 | 1080
    var fps: Int = 60                   // 30 | 60
    var hevc: Bool = true
    var bitrateMbps: Double = 15        // 5 ... 50
    var hapticsEnabled: Bool = true
    var adaptiveTriggers: Bool = true
    var showStats: Bool = false
    var touchControls: TouchControlsMode = .auto
    var swapFaceButtons: Bool = false

    static let defaultsKey = "kizuna.streamSettings"

    mutating func apply(_ newPreset: Preset) {
        preset = newPreset
        switch newPreset {
        case .lowLatency:
            resolution = 720
            fps = 60
            hevc = true
            bitrateMbps = 8
        case .balanced:
            resolution = 1080
            fps = 60
            hevc = true
            bitrateMbps = 15
        case .maxQuality:
            resolution = 1080
            fps = 60
            hevc = true
            bitrateMbps = 30
        case .custom:
            break
        }
    }

    /// Marks the preset as custom when a value no longer matches it.
    mutating func refreshPreset() {
        for candidate in [Preset.lowLatency, .balanced, .maxQuality] {
            var probe = self
            probe.apply(candidate)
            if probe.resolution == resolution && probe.fps == fps && probe.hevc == hevc
                && Int(probe.bitrateMbps) == Int(bitrateMbps) {
                preset = candidate
                return
            }
        }
        preset = .custom
    }

    static func load() -> StreamSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(StreamSettings.self, from: data) else {
            return StreamSettings()
        }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension String {
    /// RFC 1918 / link-local check used to decide whether an address is on the LAN.
    var isPrivateIPv4: Bool {
        let parts = split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }
}
