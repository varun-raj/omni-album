//
//  PasswordStore.swift
//  OmniAlbum
//
//  Album share passwords live in the Keychain (synced via iCloud Keychain when iCloud Sync is on),
//  not in albums.json, the upload queue file, or CloudKit. Keyed per share link (server + share key),
//  so two links to the same album keep their own passwords.
//

import Foundation
import Security

enum PasswordStore {
    private static let service = "com.skcript.omnialbum.albumPassword"

    private static func account(_ baseURL: String, _ shareKey: String) -> String { "\(baseURL)|\(shareKey)" }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    private static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ password: String?, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var item = query(account)
        item[kSecAttrSynchronizable as String] = UserDefaults.standard.bool(forKey: SettingsKeys.iCloudSyncEnabled)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    /// `legacyAlbumId`: earlier builds keyed by the provider's album id; a hit there is moved to the new key.
    static func get(baseURL: String, shareKey: String, legacyAlbumId: String? = nil) -> String? {
        if let found = read(account(baseURL, shareKey)) { return found }
        guard let legacyAlbumId, let old = read(legacyAlbumId) else { return nil }
        write(old, account: account(baseURL, shareKey))
        write(nil, account: legacyAlbumId)
        return old
    }

    /// nil or empty deletes.
    static func set(_ password: String?, baseURL: String, shareKey: String) {
        write(password, account: account(baseURL, shareKey))
    }
}
