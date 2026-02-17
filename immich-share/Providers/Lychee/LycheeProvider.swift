//
//  LycheeProvider.swift
//  immich-share
//
//  Concrete ShareLinkProvider for Lychee shared/public albums.
//
//  Share link format: https://example.com/gallery/{albumId}
//  Album IDs are UUIDs.
//
//  Lychee returns full image URLs directly in API responses, so Asset.id is
//  set to the best thumbnail URL. The real Lychee photo ID is stored in
//  providerData["lycheeId"]. Other size variant URLs are stored in
//  providerData as well (mediumURL, originalURL).
//

import Foundation

struct LycheeProvider: ShareLinkProvider {

    let providerType: PhotoProvider = .lychee

    private let service = LycheeService()

    // MARK: - URL Handling

    func canHandle(urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return url.path.contains("/gallery/")
    }

    func parseShareLink(_ urlString: String) throws -> ParsedShareLinkResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = trimmed
        if !s.contains("://") { s = "https://" + s }

        guard let url = URL(string: s), let host = url.host else {
            throw LycheeServiceError.invalidBaseURL
        }

        // Extract album ID from /gallery/{albumId}
        let pathComponents = url.path.split(separator: "/")
        guard let galleryIndex = pathComponents.firstIndex(of: "gallery"),
              galleryIndex + 1 < pathComponents.count else {
            throw LycheeServiceError.albumNotFound
        }

        let albumId = String(pathComponents[galleryIndex + 1])
        guard !albumId.isEmpty else {
            throw LycheeServiceError.albumNotFound
        }

        // Build base URL (scheme://host:port)
        let scheme = url.scheme ?? "https"
        var base = "\(scheme)://\(host)"
        if let port = url.port,
           (scheme == "https" && port != 443) || (scheme == "http" && port != 80) {
            base += ":\(port)"
        }

        return ParsedShareLinkResult(
            baseURL: base,
            key: albumId,
            slug: nil,
            token: nil
        )
    }

    // MARK: - Fetch Shared Link Info

    func fetchSharedLinkInfo(
        baseURL: String,
        key: String?,
        slug: String?,
        token: String?,
        password: String?
    ) async throws -> SharedLinkInfo {
        guard let albumId = key, !albumId.isEmpty else {
            throw LycheeServiceError.albumNotFound
        }

        // Initialize session (get XSRF token + session cookies)
        try await service.initSession(baseURL: baseURL, albumId: albumId)

        // Unlock if password is provided
        if let password, !password.isEmpty {
            try await service.unlockAlbum(baseURL: baseURL, albumId: albumId, password: password)
        }

        let albumResponse = try await service.fetchAlbum(baseURL: baseURL, albumId: albumId)
        let resource = albumResponse.resource

        // If password is required and no photos were returned, prompt for password
        let isPasswordProtected = albumResponse.config?.is_password_protected == true
            || resource.policy?.is_password_required == true
        if isPasswordProtected,
           (resource.photos ?? []).isEmpty,
           password == nil || password?.isEmpty == true {
            throw LycheeServiceError.passwordRequired
        }

        // Extract cover thumbnail URL
        let coverThumbId: String?
        if let thumbURL = resource.thumb?.thumb2x ?? resource.thumb?.thumb {
            coverThumbId = resolveURL(thumbURL, baseURL: baseURL)
        } else {
            coverThumbId = nil
        }

        let albumName = resource.title ?? "Lychee Album"
        let assetCount = resource.preFormattedData?.num_photos ?? (resource.photos?.count ?? 0)

        return SharedLinkInfo(
            linkId: albumId,
            albumId: albumId,
            albumName: albumName,
            thumbnailAssetId: coverThumbId,
            assetCount: assetCount,
            shareKey: albumId,
            allowUpload: false,
            allowDownload: resource.policy?.grants_download ?? true,
            showMetadata: true
        )
    }

    // MARK: - Fetch Album Detail

    func fetchAlbumDetail(
        baseURL: String,
        albumId: String,
        shareKey: String,
        password: String?
    ) async throws -> AlbumDetail {
        // Initialize session
        try await service.initSession(baseURL: baseURL, albumId: shareKey)

        // Unlock if password provided
        if let password, !password.isEmpty {
            try await service.unlockAlbum(baseURL: baseURL, albumId: shareKey, password: password)
        }

        let albumResponse = try await service.fetchAlbum(baseURL: baseURL, albumId: shareKey)
        let resource = albumResponse.resource

        // If password required and no photos, prompt
        let isPasswordProtected = albumResponse.config?.is_password_protected == true
            || resource.policy?.is_password_required == true
        if isPasswordProtected,
           (resource.photos ?? []).isEmpty,
           password == nil || password?.isEmpty == true {
            throw LycheeServiceError.passwordRequired
        }

        let assets = (resource.photos ?? []).compactMap { photo in
            mapPhoto(photo, baseURL: baseURL)
        }

        let now = ISO8601DateFormatter().string(from: Date())

        return AlbumDetail(
            albumName: resource.title ?? "Lychee Album",
            description: resource.description,
            thumbnailAssetId: assets.first?.id,
            createdAt: now,
            updatedAt: now,
            ownerName: resource.owner_name,
            ownerEmail: nil,
            ownerAvatarColor: nil,
            assetCount: assets.count,
            assets: assets,
            sharedUsers: []
        )
    }

    // MARK: - URL Builders

    func thumbnailURL(baseURL: String, assetId: String, shareKey: String) -> URL? {
        // assetId IS the full thumbnail URL for Lychee
        URL(string: assetId)
    }

    func previewURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        if let medium = asset.providerData?["mediumURL"] {
            return URL(string: medium)
        }
        if let original = asset.providerData?["originalURL"] {
            return URL(string: original)
        }
        // Fall back to the thumbnail (asset ID) if no larger variants available
        return URL(string: asset.id)
    }

    func originalURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        if let original = asset.providerData?["originalURL"] {
            return URL(string: original)
        }
        return nil
    }

    func videoPlaybackURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        guard asset.type == .video else { return nil }
        if let original = asset.providerData?["originalURL"] {
            return URL(string: original)
        }
        return nil
    }

    // MARK: - Upload (Not Supported)

    func uploadAsset(
        task: UploadTask,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        throw LycheeServiceError.uploadNotSupported
    }

    // MARK: - Private Helpers

    /// Map a Lychee photo to a generic Asset.
    private func mapPhoto(_ photo: LycheePhoto, baseURL: String) -> Asset? {
        let variants = photo.size_variants

        // Pick best thumbnail: thumb2x > thumb > small2x > small
        let thumbURL = bestURL(from: [
            variants?.thumb2x?.url,
            variants?.thumb?.url,
            variants?.small2x?.url,
            variants?.small?.url
        ], baseURL: baseURL)

        guard let thumbURL else { return nil }

        // Determine asset type from MIME
        let assetType: AssetType
        if let mime = photo.type, mime.lowercased().hasPrefix("video/") {
            assetType = .video
        } else {
            assetType = .image
        }

        let fileName = photo.title ?? "photo_\(photo.id)"
        let createdAt = photo.taken_at ?? photo.created_at

        // Get dimensions from original variant
        let width = variants?.original?.width
        let height = variants?.original?.height

        // Parse EXIF from preformatted fields
        let exif = parseExif(photo.preformatted, originalVariant: variants?.original)

        // Build providerData with resolved URLs
        var providerData: [String: String] = ["lycheeId": photo.id]
        providerData["thumbURL"] = thumbURL

        if let mediumURL = bestURL(from: [
            variants?.medium2x?.url,
            variants?.medium?.url
        ], baseURL: baseURL) {
            providerData["mediumURL"] = mediumURL
        }

        if let originalURL = resolveOptionalURL(variants?.original?.url, baseURL: baseURL) {
            providerData["originalURL"] = originalURL
        }

        return Asset(
            id: thumbURL,
            type: assetType,
            originalFileName: fileName,
            createdAt: createdAt,
            duration: nil,
            thumbhash: nil,
            width: width,
            height: height,
            exif: exif,
            providerData: providerData
        )
    }

    /// Resolve a URL that may be relative by prepending baseURL if needed.
    private func resolveURL(_ urlString: String, baseURL: String) -> String {
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return urlString
        }
        let separator = urlString.hasPrefix("/") ? "" : "/"
        return "\(baseURL)\(separator)\(urlString)"
    }

    /// Resolve an optional URL string.
    private func resolveOptionalURL(_ urlString: String?, baseURL: String) -> String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        return resolveURL(urlString, baseURL: baseURL)
    }

    /// Pick the first non-nil URL from candidates, resolving relative paths.
    private func bestURL(from candidates: [String?], baseURL: String) -> String? {
        for candidate in candidates {
            if let resolved = resolveOptionalURL(candidate, baseURL: baseURL) {
                return resolved
            }
        }
        return nil
    }

    /// Parse a human-readable filesize string like "214.25 KB" to bytes.
    private func parseFileSizeToBytes(_ str: String?) -> Int64? {
        guard let str, !str.isEmpty else { return nil }
        let parts = str.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        let unit = parts[1].uppercased()
        switch unit {
        case "B": return Int64(value)
        case "KB": return Int64(value * 1024)
        case "MB": return Int64(value * 1024 * 1024)
        case "GB": return Int64(value * 1024 * 1024 * 1024)
        default: return nil
        }
    }

    /// Parse EXIF metadata from Lychee's preformatted fields.
    private func parseExif(_ pf: LycheePreformatted?, originalVariant: LycheeSizeVariant?) -> AssetExif? {
        guard let pf else { return nil }

        // Parse aperture — may be "f/2.8", "ƒ/2.8", or just "1.8"
        let fNumber: Double? = pf.aperture.flatMap { str in
            let cleaned = str.replacingOccurrences(of: "f/", with: "")
                .replacingOccurrences(of: "ƒ/", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(cleaned)
        }

        // Parse "ISO 400" → 400
        let iso: Int? = pf.iso.flatMap { str in
            let cleaned = str.replacingOccurrences(of: "ISO ", with: "")
                .replacingOccurrences(of: "ISO", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Int(cleaned)
        }

        // Parse "50 mm" → 50.0
        let focalLength: Double? = pf.focal.flatMap { str in
            let cleaned = str.replacingOccurrences(of: " mm", with: "")
                .replacingOccurrences(of: "mm", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(cleaned)
        }

        let latitude = pf.latitude.flatMap { Double($0) }
        let longitude = pf.longitude.flatMap { Double($0) }

        let fileSizeInBytes = parseFileSizeToBytes(originalVariant?.filesize)

        let hasData = pf.make != nil || pf.model != nil || fNumber != nil ||
            iso != nil || focalLength != nil || pf.shutter != nil ||
            latitude != nil || longitude != nil || fileSizeInBytes != nil

        guard hasData else { return nil }

        return AssetExif(
            make: pf.make,
            model: pf.model,
            fNumber: fNumber,
            focalLength: focalLength,
            iso: iso,
            exposureTime: pf.shutter,
            width: originalVariant?.width,
            height: originalVariant?.height,
            fileSizeInBytes: fileSizeInBytes,
            latitude: latitude,
            longitude: longitude,
            city: nil,
            state: nil,
            country: nil,
            lensModel: pf.lens,
            orientation: nil,
            description: pf.location
        )
    }
}
