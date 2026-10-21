//
//  ImmichAccountSession.swift
//  OmniAlbum
//
//  The signed-in Immich accounts. Several can be signed in at once (different servers, or different
//  users on one server); one is active. Account details live in UserDefaults, each session token in the
//  Keychain. Each account has its own local library file.
//

import Foundation

struct ImmichAccountInfo: Codable, Identifiable, Equatable, Hashable, Sendable {
    let server: String
    let email: String
    let userId: String

    /// One user on one server.
    var id: String { "\(server)|\(userId)" }
    var host: String { URL(string: server)?.host ?? server }
}

extension ImmichCredentials {
    var info: ImmichAccountInfo { ImmichAccountInfo(server: server, email: email, userId: userId) }
    var id: String { info.id }
}

final class ImmichAccountSession {
    static let shared = ImmichAccountSession()

    private let defaults: UserDefaults
    private enum Key {
        static let accounts = "immichAccounts"
        static let active = "immichActiveAccount"
        // Pre-multi-account keys, migrated once
        static let legacyServer = "immichAccountServer"
        static let legacyEmail = "immichAccountEmail"
        static let legacyUserId = "immichAccountUserId"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateSingleAccount()
    }

    private(set) var accounts: [ImmichAccountInfo] {
        get { defaults.data(forKey: Key.accounts).flatMap { try? JSONDecoder().decode([ImmichAccountInfo].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.accounts) }
    }

    var activeID: String? {
        get {
            let stored = defaults.string(forKey: Key.active)
            return accounts.contains { $0.id == stored } ? stored : accounts.first?.id
        }
        set { defaults.set(newValue, forKey: Key.active) }
    }

    private static func tokenKey(_ userId: String) -> String { "account-token-\(userId)" }

    func credentials(for id: String) -> ImmichCredentials? {
        guard let info = accounts.first(where: { $0.id == id }),
              let token = PasswordStore.get(baseURL: info.server, shareKey: Self.tokenKey(info.userId)) else { return nil }
        return ImmichCredentials(server: info.server, email: info.email, userId: info.userId, token: token)
    }

    var activeCredentials: ImmichCredentials? { activeID.flatMap(credentials(for:)) }

    /// Adds (or refreshes) an account and makes it the active one.
    func add(_ creds: ImmichCredentials) {
        var list = accounts.filter { $0.id != creds.id }
        list.append(creds.info)
        accounts = list
        PasswordStore.set(creds.token, baseURL: creds.server, shareKey: Self.tokenKey(creds.userId))
        activeID = creds.id
    }

    func setActive(_ id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    /// Forgets one account. If it was active, another becomes active.
    func remove(_ id: String) {
        guard let info = accounts.first(where: { $0.id == id }) else { return }
        PasswordStore.set(nil, baseURL: info.server, shareKey: Self.tokenKey(info.userId))
        accounts = accounts.filter { $0.id != id }
        if defaults.string(forKey: Key.active) == id { activeID = accounts.first?.id }
    }

    private func migrateSingleAccount() {
        guard let server = defaults.string(forKey: Key.legacyServer), let email = defaults.string(forKey: Key.legacyEmail),
              let userId = defaults.string(forKey: Key.legacyUserId) else { return }
        if let token = PasswordStore.get(baseURL: server, shareKey: "account-token") {
            add(ImmichCredentials(server: server, email: email, userId: userId, token: token))
            PasswordStore.set(nil, baseURL: server, shareKey: "account-token")
        }
        [Key.legacyServer, Key.legacyEmail, Key.legacyUserId].forEach { defaults.removeObject(forKey: $0) }
    }
}
