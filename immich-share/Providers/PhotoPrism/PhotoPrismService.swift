//
//  PhotoPrismService.swift
//  immich-share
//
//  REST API client for PhotoPrism. Handles both public and private mode
//  instances for share link access.
//
//  Public mode: GET /api/v1/session (no auth) returns config with previewToken
//  Private mode: POST /api/v1/session with {"token":"...","password":"..."}
//
//  Thumbnails always use previewToken in URL path (no auth header needed).
//

import Foundation

// MARK: - Error Types

enum PhotoPrismServiceError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case httpError(status: Int, message: String?)
    case passwordRequired
    case linkExpired
    case sessionFailed(String)
    case albumNotFound

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url): return "Invalid server URL: \(url)"
        case .invalidResponse: return "Invalid response from server."
        case .httpError(let status, let message):
            if let message, !message.isEmpty { return "Server error (\(status)): \(message)" }
            return "Server error: \(status)"
        case .passwordRequired: return "This shared album requires a password."
        case .linkExpired: return "This share link has expired."
        case .sessionFailed(let reason): return "Failed to create session: \(reason)"
        case .albumNotFound: return "Could not find the shared album."
        }
    }
}

// MARK: - Session Model

struct PhotoPrismSession {
    let accessToken: String?
    let previewToken: String
    let downloadToken: String
    let isPublic: Bool
}

// MARK: - API Response Models

struct PhotoPrismSessionResponse: Codable {
    let id: String?
    let access_token: String?
    let config: PhotoPrismConfig?
    let status: String?

    struct PhotoPrismConfig: Codable {
        let previewToken: String?
        let downloadToken: String?
        let albums: [PhotoPrismConfigAlbum]?

        // Tells us if the instance is in public mode
        let authMode: String?
        // Also available as a bool
        let `public`: Bool?

        private enum CodingKeys: String, CodingKey {
            case previewToken, downloadToken, albums, authMode
            case `public` = "public"
        }
    }

    struct PhotoPrismConfigAlbum: Codable {
        let UID: String
        let Slug: String?
        let Title: String?
        let Thumb: String?
    }
}

struct PhotoPrismAlbum: Codable {
    let UID: String
    let Title: String
    let Description: String?
    let Thumb: String?
    let CreatedAt: String?
    let UpdatedAt: String?
    let PhotoCount: Int?
}

struct PhotoPrismPhoto: Codable {
    let UID: String
    let Hash: String
    let TypeSrc: String?
    let Title: String?

    /// The media type (e.g. "image", "video", "live", "raw")
    var mediaType: String? { TypeSrc }

    private enum CodingKeys: String, CodingKey {
        case UID, Hash, Title, TakenAt, TakenAtLocal
        case Width, Height, CameraMake, CameraModel
        case LensMake, LensModel, FNumber, Iso, FocalLength
        case Exposure, Lat, Lng, Country, Files
        case TypeSrc = "Type"
    }

    let TakenAt: String?
    let TakenAtLocal: String?
    let Width: Int?
    let Height: Int?
    let CameraMake: String?
    let CameraModel: String?
    let LensMake: String?
    let LensModel: String?
    let FNumber: Double?
    let Iso: Int?
    let FocalLength: Int?
    let Exposure: String?
    let Lat: Double?
    let Lng: Double?
    let Country: String?
    let Files: [PhotoPrismFile]?
}

struct PhotoPrismFile: Codable {
    let UID: String?
    let Hash: String
    let Width: Int?
    let Height: Int?
    let Primary: Bool?
    let FileType: String?
    let MediaType: String?
    let Name: String?
    let Size: Int64?
}

/// Combined result from resolving a share link
struct PhotoPrismShareInfo {
    let session: PhotoPrismSession
    let albumUID: String
    let albumTitle: String?
    let albumThumb: String?
}

// MARK: - Service

final class PhotoPrismService {
    private let urlSession: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }

    /// Normalize a base URL to scheme://host[:port]
    func normalizeBaseURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host else { return nil }
        let scheme = url.scheme ?? "https"
        var base = "\(scheme)://\(host)"
        if let port = url.port, (scheme == "https" && port != 443) || (scheme == "http" && port != 80) {
            base += ":\(port)"
        }
        return base
    }

    // MARK: - Share Link Resolution

    /// Resolve a share link by fetching the share page HTML, extracting the album UID,
    /// and establishing a session (public or private).
    func resolveShareLink(
        baseURL: String,
        token: String,
        slug: String?,
        password: String?
    ) async throws -> PhotoPrismShareInfo {
        guard let base = normalizeBaseURL(baseURL) else {
            throw PhotoPrismServiceError.invalidBaseURL(baseURL)
        }

        // Step 1: Fetch share page HTML to extract album UID from og:url
        let albumUID = try await fetchAlbumUIDFromSharePage(
            base: base, token: token, slug: slug
        )

        // Step 2: Establish session — try GET (public mode) first, then POST (private mode)
        let session = try await establishSession(
            base: base, token: token, password: password
        )

        // Step 3: Find album info from session config or fetch it
        let (title, thumb) = albumInfoFromSession(session: session, albumUID: albumUID)

        return PhotoPrismShareInfo(
            session: session,
            albumUID: albumUID,
            albumTitle: title,
            albumThumb: thumb
        )
    }

    // MARK: - Session Creation

    /// Try to establish a session. First attempts GET (works for public instances),
    /// then falls back to POST with share token (for private instances).
    func establishSession(
        base: String,
        token: String,
        password: String?
    ) async throws -> PhotoPrismSession {
        // Try GET /api/v1/session first (public mode — no auth needed)
        if let publicSession = try? await getSession(base: base) {
            return publicSession
        }

        // Fall back to POST /api/v1/session with share token (private mode)
        return try await postSession(base: base, token: token, password: password)
    }

    /// GET /api/v1/session — works on public instances without authentication
    private func getSession(base: String) async throws -> PhotoPrismSession {
        guard let url = URL(string: "\(base)/api/v1/session") else {
            throw PhotoPrismServiceError.invalidBaseURL(base)
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw PhotoPrismServiceError.invalidResponse
        }

        let sessionResponse = try JSONDecoder().decode(PhotoPrismSessionResponse.self, from: data)

        guard let previewToken = sessionResponse.config?.previewToken, !previewToken.isEmpty else {
            throw PhotoPrismServiceError.sessionFailed("No preview token in public session")
        }

        let isPublic = sessionResponse.config?.public == true ||
                       sessionResponse.config?.authMode == "public"

        guard isPublic else {
            throw PhotoPrismServiceError.sessionFailed("Not a public instance")
        }

        return PhotoPrismSession(
            accessToken: sessionResponse.access_token ?? sessionResponse.id,
            previewToken: previewToken,
            downloadToken: sessionResponse.config?.downloadToken ?? "public",
            isPublic: true
        )
    }

    /// POST /api/v1/session with share token — works on private instances
    private func postSession(
        base: String,
        token: String,
        password: String?
    ) async throws -> PhotoPrismSession {
        guard let url = URL(string: "\(base)/api/v1/session") else {
            throw PhotoPrismServiceError.invalidBaseURL(base)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = ["token": token]
        if let password, !password.isEmpty {
            body["password"] = password
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PhotoPrismServiceError.invalidResponse
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            if let responseStr = String(data: data, encoding: .utf8)?.lowercased(),
               responseStr.contains("expired") {
                throw PhotoPrismServiceError.linkExpired
            }
            throw PhotoPrismServiceError.passwordRequired
        }

        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw PhotoPrismServiceError.httpError(status: http.statusCode, message: message)
        }

        let sessionResponse = try JSONDecoder().decode(PhotoPrismSessionResponse.self, from: data)

        guard let accessToken = sessionResponse.access_token ?? sessionResponse.id,
              !accessToken.isEmpty else {
            throw PhotoPrismServiceError.sessionFailed("No access token in response")
        }

        return PhotoPrismSession(
            accessToken: accessToken,
            previewToken: sessionResponse.config?.previewToken ?? "public",
            downloadToken: sessionResponse.config?.downloadToken ?? "public",
            isPublic: false
        )
    }

    // MARK: - Album UID from Share Page

    /// Fetch the share page HTML and extract album UID from the og:url meta tag.
    /// The og:url contains the real album UID (e.g. /s/{token}/{albumUID}).
    private func fetchAlbumUIDFromSharePage(
        base: String,
        token: String,
        slug: String?
    ) async throws -> String {
        let slugPart = slug ?? ""
        let shareURL = "\(base)/s/\(token)/\(slugPart)"

        guard let url = URL(string: shareURL) else {
            throw PhotoPrismServiceError.invalidBaseURL(shareURL)
        }

        let (data, response) = try await urlSession.data(for: URLRequest(url: url))

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw PhotoPrismServiceError.albumNotFound
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw PhotoPrismServiceError.invalidResponse
        }

        // Parse og:url meta tag: <meta property="og:url" content="https://host/s/{token}/{albumUID}">
        if let albumUID = extractAlbumUID(fromHTML: html, token: token) {
            return albumUID
        }

        // If we can't find the album UID in HTML, the slug itself might be the UID
        if let slug, !slug.isEmpty {
            return slug
        }

        throw PhotoPrismServiceError.albumNotFound
    }

    /// Extract album UID from og:url meta tag in HTML
    private func extractAlbumUID(fromHTML html: String, token: String) -> String? {
        // Look for: content="https://host/s/{token}/{albumUID}"
        // The pattern: /s/{token}/ followed by the album UID
        let pattern = "/s/\(NSRegularExpression.escapedPattern(for: token))/([a-z0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let uidRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let uid = String(html[uidRange])
        // The slug (e.g. "berlin") and the albumUID (e.g. "artiskh2amkzizr6") are different.
        // The og:url always uses the albumUID, not the slug.
        return uid
    }

    /// Try to find album info from session config albums list
    private func albumInfoFromSession(
        session: PhotoPrismSession,
        albumUID: String
    ) -> (title: String?, thumb: String?) {
        // Session config won't have albums list in non-decoded form here,
        // so we return nil — the provider will handle naming via the slug
        return (nil, nil)
    }

    // MARK: - Photo Search

    /// Search photos in an album. Returns photos and total count from headers.
    func searchPhotos(
        baseURL: String,
        albumUID: String,
        accessToken: String?,
        count: Int = 100,
        offset: Int = 0
    ) async throws -> (photos: [PhotoPrismPhoto], totalCount: Int?) {
        guard let base = normalizeBaseURL(baseURL) else {
            throw PhotoPrismServiceError.invalidBaseURL(baseURL)
        }

        var comp = URLComponents(string: "\(base)/api/v1/photos")
        comp?.queryItems = [
            URLQueryItem(name: "s", value: albumUID),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "merged", value: "true"),
            URLQueryItem(name: "public", value: "true")
        ]

        guard let url = comp?.url else {
            throw PhotoPrismServiceError.invalidBaseURL(baseURL)
        }

        var request = URLRequest(url: url)
        if let accessToken {
            request.setValue(accessToken, forHTTPHeaderField: "X-Auth-Token")
        }

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PhotoPrismServiceError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw PhotoPrismServiceError.httpError(status: http.statusCode, message: message)
        }

        let photos = try JSONDecoder().decode([PhotoPrismPhoto].self, from: data)
        let totalCount = http.value(forHTTPHeaderField: "X-Count").flatMap { Int($0) }

        return (photos, totalCount)
    }

    /// Fetch all photos in an album, paginating as needed
    func fetchAllPhotos(
        baseURL: String,
        albumUID: String,
        accessToken: String?
    ) async throws -> [PhotoPrismPhoto] {
        let pageSize = 100
        var allPhotos: [PhotoPrismPhoto] = []
        var offset = 0

        while true {
            let (photos, _) = try await searchPhotos(
                baseURL: baseURL,
                albumUID: albumUID,
                accessToken: accessToken,
                count: pageSize,
                offset: offset
            )

            allPhotos.append(contentsOf: photos)

            if photos.count < pageSize {
                break
            }

            offset += pageSize
        }

        return allPhotos
    }
}
