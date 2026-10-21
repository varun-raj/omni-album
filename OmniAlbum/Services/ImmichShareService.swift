//
//  ImmichShareService.swift
//  OmniAlbum
//
//  Fetches shared link and album data from Immich API.
//  - GET /api/shared-links/me?key=... → SharedLinkResponse (album metadata, assetCount; assets may be empty)
//  - GET /api/albums/[id]?key=[shareKey] → AlbumWithAssetsResponse (full assets array)
//

import Foundation

enum ImmichShareServiceError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case httpError(status: Int, message: String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url): return "Invalid server URL: \(url)"
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let status, let message):
            if let message = message, !message.isEmpty { return "Server error (\(status)): \(message)" }
            return "Server error: \(status)"
        case .decodingError(let e): return "Failed to parse response: \(e.localizedDescription)"
        }
    }
}

final class ImmichShareService {
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        // API returns camelCase (albumName, albumThumbnailAssetId, etc.) — use default key decoding
    }

    /// Fetches shared link info. Uses key (required for your server); optionally slug, token, password.
    /// Response includes album metadata and assetCount; assets array may be empty. Use fetchAlbumWithAssets for full assets.
    func fetchSharedLink(
        baseURL: String,
        key: String? = nil,
        slug: String? = nil,
        token: String? = nil,
        password: String? = nil
    ) async throws -> SharedLinkResponse {
        guard let base = normalizeBaseURL(baseURL) else {
            throw ImmichShareServiceError.invalidBaseURL(baseURL)
        }
        var components = URLComponents(string: "\(base)/api/shared-links/me")!
        var queryItems: [URLQueryItem] = []
        if let key = key, !key.isEmpty { queryItems.append(URLQueryItem(name: "key", value: key)) }
        if let slug = slug, !slug.isEmpty { queryItems.append(URLQueryItem(name: "slug", value: slug)) }
        if let token = token, !token.isEmpty { queryItems.append(URLQueryItem(name: "token", value: token)) }
        if let password = password, !password.isEmpty { queryItems.append(URLQueryItem(name: "password", value: password)) }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw ImmichShareServiceError.invalidBaseURL(baseURL) }
        return try await perform(SharedLinkResponse.self, url: url)
    }

    /// Fetches full album with assets. Requires share key for public access.
    func fetchAlbumWithAssets(baseURL: String, albumId: String, shareKey: String, password: String? = nil) async throws -> AlbumWithAssetsResponse {
        guard let base = normalizeBaseURL(baseURL) else {
            throw ImmichShareServiceError.invalidBaseURL(baseURL)
        }
        var components = URLComponents(string: "\(base)/api/albums/\(albumId)")!
        var queryItems = [URLQueryItem(name: "key", value: shareKey)]
        if let password = password, !password.isEmpty {
            queryItems.append(URLQueryItem(name: "password", value: password))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw ImmichShareServiceError.invalidBaseURL(baseURL) }
        return try await perform(AlbumWithAssetsResponse.self, url: url)
    }

    private func normalizeBaseURL(_ raw: String) -> String? {
        ServerBaseURL.normalize(raw)
    }

    private func perform<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ImmichShareServiceError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw ImmichShareServiceError.httpError(status: http.statusCode, message: message)
        }
        // Decode off the calling actor (e.g. MainActor) to avoid blocking the UI for large payloads.
        return try await Task.detached {
            try self.decoder.decode(T.self, from: data)
        }.value
    }
}
