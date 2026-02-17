//
//  LycheeService.swift
//  OmniAlbum
//
//  REST API client for Lychee. Handles public and password-protected albums.
//
//  Lychee uses Laravel's CSRF protection, so all API requests require:
//  1. A session cookie (obtained by visiting the gallery page)
//  2. An XSRF-TOKEN cookie sent back as X-XSRF-TOKEN header
//  3. Content-Type: application/json even on GET requests
//
//  Public albums: GET /api/v2/Album?album_id={id}
//  Password-protected: POST /api/v2/Album::unlock then re-fetch
//

import Foundation

// MARK: - Error Types

enum LycheeServiceError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpError(status: Int, message: String?)
    case passwordRequired
    case albumNotFound
    case uploadNotSupported

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Invalid Lychee server URL."
        case .invalidResponse: return "Invalid response from Lychee server."
        case .httpError(let status, let message):
            if let message, !message.isEmpty { return "Server error (\(status)): \(message)" }
            return "Server error: \(status)"
        case .passwordRequired: return "This album requires a password."
        case .albumNotFound: return "Could not find the album."
        case .uploadNotSupported: return "Lychee does not support uploads via share links."
        }
    }
}

// MARK: - API Response Models

struct LycheeAlbumResponse: Codable {
    let config: LycheeConfig?
    let resource: LycheeAlbumResource
}

struct LycheeConfig: Codable {
    let is_model_album: Bool?
    let is_password_protected: Bool?
}

struct LycheeAlbumResource: Codable {
    let id: String
    let title: String?
    let description: String?
    let photos: [LycheePhoto]?
    let policy: LycheePolicy?
    let cover_id: String?
    let owner_name: String?
    let thumb: LycheeThumb?
    let preFormattedData: LycheePreFormattedData?
}

struct LycheePreFormattedData: Codable {
    let num_photos: Int?
    let title: String?
    let description: String?
}

struct LycheePhoto: Codable {
    let id: String
    let type: String?
    let title: String?
    let taken_at: String?
    let created_at: String?
    let size_variants: LycheeSizeVariants?
    let preformatted: LycheePreformatted?
}

struct LycheeSizeVariants: Codable {
    let thumb: LycheeSizeVariant?
    let thumb2x: LycheeSizeVariant?
    let small: LycheeSizeVariant?
    let small2x: LycheeSizeVariant?
    let medium: LycheeSizeVariant?
    let medium2x: LycheeSizeVariant?
    let original: LycheeSizeVariant?
}

struct LycheeSizeVariant: Codable {
    let url: String?
    let width: Int?
    let height: Int?
    let filesize: String?
}

struct LycheePreformatted: Codable {
    let make: String?
    let model: String?
    let shutter: String?
    let aperture: String?
    let iso: String?
    let lens: String?
    let focal: String?
    let latitude: String?
    let longitude: String?
    let location: String?
    let filesize: String?
    let resolution: String?
}

struct LycheePolicy: Codable {
    let is_public: Bool?
    let grants_download: Bool?
    let grants_upload: Bool?
    let grants_full_photo_access: Bool?
    let is_password_required: Bool?
}

struct LycheeThumb: Codable {
    let id: String?
    let type: String?
    let thumb: String?
    let thumb2x: String?
}

// MARK: - Service

final class LycheeService: Sendable {
    private let urlSession: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        self.urlSession = URLSession(configuration: config)
    }

    /// Initialize a session by fetching the gallery page. This sets the XSRF-TOKEN
    /// and session cookies required by Laravel for subsequent API calls.
    func initSession(baseURL: String, albumId: String) async throws {
        guard let url = URL(string: "\(baseURL)/gallery/\(albumId)") else {
            throw LycheeServiceError.invalidBaseURL
        }

        let (_, response) = try await urlSession.data(for: URLRequest(url: url))

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw LycheeServiceError.albumNotFound
        }
    }

    /// Fetch album data from Lychee API v2.
    func fetchAlbum(baseURL: String, albumId: String) async throws -> LycheeAlbumResponse {
        guard var components = URLComponents(string: "\(baseURL)/api/v2/Album") else {
            throw LycheeServiceError.invalidBaseURL
        }
        components.queryItems = [URLQueryItem(name: "album_id", value: albumId)]

        guard let url = components.url else {
            throw LycheeServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add XSRF token from cookies
        if let xsrfToken = xsrfToken(for: baseURL) {
            request.setValue(xsrfToken, forHTTPHeaderField: "X-XSRF-TOKEN")
        }

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LycheeServiceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw LycheeServiceError.passwordRequired
        }

        if http.statusCode == 404 {
            throw LycheeServiceError.albumNotFound
        }

        // 406 means session expired or missing — re-init and throw for caller to retry
        if http.statusCode == 406 {
            let message = String(data: data, encoding: .utf8)
            throw LycheeServiceError.httpError(status: 406, message: message)
        }

        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw LycheeServiceError.httpError(status: http.statusCode, message: message)
        }

        return try JSONDecoder().decode(LycheeAlbumResponse.self, from: data)
    }

    /// Unlock a password-protected album. Sets a session cookie for subsequent requests.
    func unlockAlbum(baseURL: String, albumId: String, password: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/v2/Album::unlock") else {
            throw LycheeServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let xsrfToken = xsrfToken(for: baseURL) {
            request.setValue(xsrfToken, forHTTPHeaderField: "X-XSRF-TOKEN")
        }

        let body: [String: String] = ["album_id": albumId, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LycheeServiceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw LycheeServiceError.passwordRequired
        }

        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw LycheeServiceError.httpError(status: http.statusCode, message: message)
        }
    }

    // MARK: - Private Helpers

    /// Extract the XSRF-TOKEN value from cookies for the given base URL.
    private func xsrfToken(for baseURL: String) -> String? {
        guard let url = URL(string: baseURL),
              let cookies = urlSession.configuration.httpCookieStorage?.cookies(for: url) else {
            return nil
        }
        guard let cookie = cookies.first(where: { $0.name == "XSRF-TOKEN" }) else {
            return nil
        }
        // The cookie value is URL-encoded; decode it for use in the header
        return cookie.value.removingPercentEncoding ?? cookie.value
    }
}
