//
//  ImmichAccountClient.swift
//  OmniAlbum
//
//  Signed-in access to an Immich server. Sync needs a session, so sign-in is email + password
//  (an API key has no session and the server refuses /sync with one). Only the session token is stored.
//

import Foundation

struct ImmichCredentials: Equatable, Sendable {
    let server: String   // normalized base URL, may include a path prefix
    let email: String
    let userId: String
    let token: String
}

enum ImmichAccountError: LocalizedError {
    case invalidServer
    case badCredentials
    case unauthorized
    case server(status: Int, body: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "That doesn't look like a server address."
        case .badCredentials: return "Email or password is wrong."
        case .unauthorized: return "Your session expired. Sign in again."
        case .server(let status, let body): return "Server error \(status): \(body.prefix(200))"
        case .badResponse: return "Unexpected response from the server."
        }
    }
}

struct ImmichAccountClient: Sendable {
    let credentials: ImmichCredentials
    var session: URLSession = .shared

    // MARK: Sign in

    static func signIn(server: String, email: String, password: String, session: URLSession = .shared) async throws -> ImmichCredentials {
        guard var base = ServerBaseURL.normalize(server) else { throw ImmichAccountError.invalidServer }
        if base.hasSuffix("/api") { base.removeLast(4) } // people paste the API address
        guard let url = URL(string: base + "/api/auth/login") else { throw ImmichAccountError.invalidServer }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImmichAccountError.badResponse }
        if http.statusCode == 401 { throw ImmichAccountError.badCredentials }
        guard (200...299).contains(http.statusCode) else {
            throw ImmichAccountError.server(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        struct Login: Decodable { let accessToken: String; let userId: String; let userEmail: String? }
        guard let login = try? JSONDecoder().decode(Login.self, from: data) else { throw ImmichAccountError.badResponse }
        return ImmichCredentials(server: base, email: login.userEmail ?? email, userId: login.userId, token: login.accessToken)
    }

    // MARK: Requests

    func request(_ path: String, method: String = "GET", json: Any? = nil) throws -> URLRequest {
        guard let url = URL(string: credentials.server + path) else { throw ImmichAccountError.invalidServer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    /// Tells the server which changes are safely stored, so the next stream resumes after them.
    func ack(_ acks: [String]) async throws {
        guard !acks.isEmpty else { return }
        let (data, response) = try await session.data(for: try request("/api/sync/ack", method: "POST", json: ["acks": acks]))
        try Self.check(response, data: data)
    }

    static func check(_ response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw ImmichAccountError.badResponse }
        if http.statusCode == 401 { throw ImmichAccountError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw ImmichAccountError.server(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// EXIF for one asset (GET /api/assets/{id}); nil if the server has none.
    func fetchExif(assetId: String) async throws -> AssetExif? {
        let (data, response) = try await session.data(for: try request("/api/assets/\(assetId)"))
        try Self.check(response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let e = root["exifInfo"] as? [String: Any] else { return nil }
        func num(_ k: String) -> Double? { (e[k] as? NSNumber)?.doubleValue }
        return AssetExif(make: e["make"] as? String, model: e["model"] as? String, fNumber: num("fNumber"), focalLength: num("focalLength"),
                         iso: num("iso").map(Int.init), exposureTime: e["exposureTime"] as? String,
                         width: num("exifImageWidth").map(Int.init), height: num("exifImageHeight").map(Int.init),
                         fileSizeInBytes: num("fileSizeInByte").map(Int64.init), latitude: num("latitude"), longitude: num("longitude"),
                         city: e["city"] as? String, state: e["state"] as? String, country: e["country"] as? String,
                         lensModel: e["lensModel"] as? String, orientation: e["orientation"] as? String, description: e["description"] as? String)
    }

    // MARK: Image URLs (loaded with `authHeaders`, namespaced by `cacheScope`)

    var authHeaders: [String: String] { ["Authorization": "Bearer \(credentials.token)"] }
    /// Cache namespace: one account's images never come out of another's cache entries.
    var cacheScope: String { credentials.id }

    func thumbnailURL(assetId: String) -> URL? {
        URL(string: "\(credentials.server)/api/assets/\(assetId)/thumbnail?size=thumbnail")
    }

    func originalURL(assetId: String) -> URL? {
        URL(string: "\(credentials.server)/api/assets/\(assetId)/original")
    }

    func videoPlaybackURL(assetId: String) -> URL? {
        URL(string: "\(credentials.server)/api/assets/\(assetId)/video/playback")
    }

    func previewURL(assetId: String) -> URL? {
        URL(string: "\(credentials.server)/api/assets/\(assetId)/thumbnail?size=preview")
    }
}
