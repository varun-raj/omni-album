//
//  PasswordStore.swift
//  OmniAlbum
//
//  Album share passwords live in the Keychain (synced via iCloud Keychain when iCloud Sync is on),
//  not in albums.json, the upload queue file, or CloudKit. Keyed by the provider's album id.
//

import Foundation
import Security

enum PasswordStore {
    private static let service = "com.skcript.omnialbum.albumPassword"

    private static func query(_ albumId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: albumId,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    static func get(_ albumId: String) -> String? {
        var q = query(albumId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil or empty deletes.
    static func set(_ password: String?, for albumId: String) {
        SecItemDelete(query(albumId) as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var item = query(albumId)
        item[kSecAttrSynchronizable as String] = UserDefaults.standard.bool(forKey: SettingsKeys.iCloudSyncEnabled)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
