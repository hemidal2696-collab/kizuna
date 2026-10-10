// Kizuna for iOS/iPadOS - small Keychain wrapper (generic passwords)
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Kizuna contributors

import Foundation
import Security

enum Keychain {
    private static let service = "ro.kizuna.remoteplay"
    /// Used only if the Keychain is unusable (e.g. a broken re-signing
    /// without keychain-access-groups); documented in README-ro.md.
    private static let fallbackPrefix = "kizuna.kcfallback."

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackPrefix + account)
            return true
        }
        LogStore.shared.info("Keychain write failed (\(status)), using app storage fallback")
        UserDefaults.standard.set(data, forKey: fallbackPrefix + account)
        return false
    }

    static func get(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return data
        }
        return UserDefaults.standard.data(forKey: fallbackPrefix + account)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + account)
    }

    static func setCodable<T: Encodable>(_ value: T, for account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, for: account)
    }

    static func getCodable<T: Decodable>(_ type: T.Type, for account: String) -> T? {
        guard let data = get(account) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
