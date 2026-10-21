//
//  ImmichAccountSession.swift
//  OmniAlbum
//
//  Remembers the signed-in account across launches (token in the Keychain) and lets image loads
//  carry the Authorization header, for the account's own server only.
//

import Foundation
import Kingfisher

final class ImmichAccountSession: @unchecked Sendable {
    static let shared = ImmichAccountSession()

    private let lock = NSLock()
    private var current: ImmichCredentials?
    private static let tokenKey = "account-token"
    private enum Defaults {
        static let server = "immichAccountServer"
        static let email = "immichAccountEmail"
        static let userId = "immichAccountUserId"
    }

    var credentials: ImmichCredentials? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Restore the previous sign-in, if any.
    func restore() -> ImmichCredentials? {
        let d = UserDefaults.standard
        guard let server = d.string(forKey: Defaults.server), let email = d.string(forKey: Defaults.email),
              let userId = d.string(forKey: Defaults.userId),
              let token = PasswordStore.get(baseURL: server, shareKey: Self.tokenKey) else { return nil }
        let creds = ImmichCredentials(server: server, email: email, userId: userId, token: token)
        set(creds)
        return creds
    }

    func save(_ creds: ImmichCredentials) {
        let d = UserDefaults.standard
        d.set(creds.server, forKey: Defaults.server)
        d.set(creds.email, forKey: Defaults.email)
        d.set(creds.userId, forKey: Defaults.userId)
        PasswordStore.set(creds.token, baseURL: creds.server, shareKey: Self.tokenKey)
        set(creds)
    }

    func clear() {
        if let creds = credentials { PasswordStore.set(nil, baseURL: creds.server, shareKey: Self.tokenKey) }
        let d = UserDefaults.standard
        [Defaults.server, Defaults.email, Defaults.userId].forEach { d.removeObject(forKey: $0) }
        set(nil)
    }

    private func set(_ creds: ImmichCredentials?) {
        lock.lock(); current = creds; lock.unlock()
    }

    /// Adds the bearer token to requests to the account's server (and only there), so shared-link
    /// albums on other hosts never see it. Kingfisher caches by URL, so a new token doesn't refetch images.
    static let requestModifier = AnyModifier { request in
        guard let creds = ImmichAccountSession.shared.credentials,
              let url = request.url, let serverURL = URL(string: creds.server),
              url.host == serverURL.host, url.port == serverURL.port, url.path.hasPrefix(serverURL.path)
        else { return request }
        var r = request
        r.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        return r
    }
}
