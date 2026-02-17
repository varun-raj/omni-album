//
//  PhotoPrismProvider.swift
//  OmniAlbum
//
//  Concrete ShareLinkProvider for PhotoPrism shared albums.
//  Wraps PhotoPrismService for session-based API access.
//
//  Share link format: https://example.com/s/{token}/{slug}
//
//  The shareKey is a pipe-separated composite:
//    "{linkToken}|{previewToken}|{downloadToken}|{albumUID}"
//  This allows URL builders to extract the previewToken for thumbnails
//  without needing a fresh session.
//

import Foundation

// MARK: - Link Parsing Error

enum PhotoPrismShareLinkError: LocalizedError {
    case notAValidURL(String)
    case missingSharePath
    case missingToken
    case uploadNotSupported

    var errorDescription: String? {
        switch self {
        case .notAValidURL(let s): return "Not a valid URL: \(s)"
        case .missingSharePath: return "URL must be a PhotoPrism share link (path contains /s/)."
        case .missingToken: return "Share link must include an album token."
        case .uploadNotSupported: return "PhotoPrism does not support uploads via share links."
        }
    }
}

// MARK: - Provider

final class PhotoPrismProvider: ShareLinkProvider, @unchecked Sendable {
    let providerType: PhotoProvider = .photoprism

    private let service = PhotoPrismService()

    // MARK: - Composite shareKey helpers

    /// Build composite shareKey: "linkToken|previewToken|downloadToken|albumUID"
    private func buildCompositeKey(
        linkToken: String,
        previewToken: String,
        downloadToken: String,
        albumUID: String
    ) -> String {
        "\(linkToken)|\(previewToken)|\(downloadToken)|\(albumUID)"
    }

    /// Parse composite shareKey into (linkToken, previewToken, downloadToken, albumUID)
    private func parseCompositeKey(_ shareKey: String) -> (linkToken: String, previewToken: String, downloadToken: String, albumUID: String)? {
        let parts = shareKey.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        return (parts[0], parts[1], parts[2], parts[3])
    }

    // MARK: - Link Handling

    func canHandle(urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)") else {
            return false
        }
        let pathComponents = url.path.split(separator: "/")
        // Must have /s/{token} pattern and NOT match other providers
        guard let sIndex = pathComponents.firstIndex(of: "s"),
              sIndex + 1 < pathComponents.count else { return false }
        // Exclude Immich share links (/share/) and Nextcloud (/apps/photos/)
        return !trimmed.contains("/share/") && !trimmed.contains("/apps/photos/")
    }

    func parseShareLink(_ urlString: String) throws -> ParsedShareLinkResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = trimmed
        if !s.contains("://") { s = "https://" + s }

        guard let url = URL(string: s), let host = url.host else {
            throw PhotoPrismShareLinkError.notAValidURL(trimmed)
        }

        let pathComponents = url.path.split(separator: "/")
        guard let sIndex = pathComponents.firstIndex(of: "s"),
              sIndex + 1 < pathComponents.count else {
            throw PhotoPrismShareLinkError.missingSharePath
        }

        let token = String(pathComponents[sIndex + 1])
        guard !token.isEmpty else {
            throw PhotoPrismShareLinkError.missingToken
        }

        // Slug is optional (the part after the token)
        let slug: String? = (sIndex + 2 < pathComponents.count)
            ? String(pathComponents[sIndex + 2])
            : nil

        // Build base URL
        let scheme = url.scheme ?? "https"
        var base = "\(scheme)://\(host)"
        if let port = url.port, (scheme == "https" && port != 443) || (scheme == "http" && port != 80) {
            base += ":\(port)"
        }

        return ParsedShareLinkResult(
            baseURL: base,
            key: token,
            slug: slug,
            token: token
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
        guard let linkToken = token ?? key, !linkToken.isEmpty else {
            throw PhotoPrismShareLinkError.missingToken
        }

        // Resolve the share link: fetch HTML for album UID, establish session
        let shareInfo = try await service.resolveShareLink(
            baseURL: baseURL,
            token: linkToken,
            slug: slug,
            password: password
        )

        // Get photo count — X-Count returns items in response (not total),
        // so we request a large page to get the real count in one shot
        let (photos, returnedCount) = try await service.searchPhotos(
            baseURL: baseURL,
            albumUID: shareInfo.albumUID,
            accessToken: shareInfo.session.accessToken,
            count: 10000,
            offset: 0
        )
        let photoCount = returnedCount ?? photos.count
        let coverHash = photos.first?.primaryFileHash

        // Build composite shareKey
        let compositeKey = buildCompositeKey(
            linkToken: linkToken,
            previewToken: shareInfo.session.previewToken,
            downloadToken: shareInfo.session.downloadToken,
            albumUID: shareInfo.albumUID
        )

        // Determine album name from share info, slug, or fallback
        let albumName: String
        if let title = shareInfo.albumTitle, !title.isEmpty {
            albumName = title
        } else if let slug, !slug.isEmpty {
            // Convert slug to readable name (e.g. "berlin" → "Berlin", "my-photos" → "My Photos")
            albumName = slug.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        } else {
            albumName = "Shared Album"
        }

        return SharedLinkInfo(
            linkId: linkToken,
            albumId: shareInfo.albumUID,
            albumName: albumName,
            thumbnailAssetId: coverHash,
            assetCount: photoCount,
            shareKey: compositeKey,
            allowUpload: false,
            allowDownload: true,
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
        guard let keys = parseCompositeKey(shareKey) else {
            throw PhotoPrismShareLinkError.missingToken
        }

        // Re-establish session (previous access token may have expired)
        guard let base = service.normalizeBaseURL(baseURL) else {
            throw PhotoPrismServiceError.invalidBaseURL(baseURL)
        }

        let ppSession = try await service.establishSession(
            base: base,
            token: keys.linkToken,
            password: password
        )

        // Fetch all photos
        let allPhotos = try await service.fetchAllPhotos(
            baseURL: baseURL,
            albumUID: keys.albumUID,
            accessToken: ppSession.accessToken
        )

        // Map photos to Assets
        let assets = allPhotos.compactMap { photo -> Asset? in
            mapPhotoToAsset(photo)
        }

        let now = ISO8601DateFormatter().string(from: Date())

        return AlbumDetail(
            albumName: albumId,
            description: nil,
            thumbnailAssetId: assets.first?.id,
            createdAt: now,
            updatedAt: now,
            ownerName: nil,
            ownerEmail: nil,
            ownerAvatarColor: nil,
            assetCount: assets.count,
            assets: assets,
            sharedUsers: []
        )
    }

    // MARK: - URL Builders

    func thumbnailURL(baseURL: String, assetId: String, shareKey: String) -> URL? {
        guard let keys = parseCompositeKey(shareKey) else { return nil }
        return URL(string: "\(baseURL)/api/v1/t/\(assetId)/\(keys.previewToken)/tile_500")
    }

    func previewURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        guard let keys = parseCompositeKey(shareKey) else { return nil }
        let hash = asset.providerData?["fileHash"] ?? asset.id
        return URL(string: "\(baseURL)/api/v1/t/\(hash)/\(keys.previewToken)/fit_2048")
    }

    func originalURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        guard let keys = parseCompositeKey(shareKey) else { return nil }
        let hash = asset.providerData?["fileHash"] ?? asset.id
        return URL(string: "\(baseURL)/api/v1/t/\(hash)/\(keys.previewToken)/fit_4096")
    }

    func videoPlaybackURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        guard asset.type == .video else { return nil }
        guard let keys = parseCompositeKey(shareKey) else { return nil }
        let hash = asset.providerData?["fileHash"] ?? asset.id
        return URL(string: "\(baseURL)/api/v1/videos/\(hash)/\(keys.previewToken)/avc")
    }

    // MARK: - Upload (Not Supported)

    func uploadAsset(
        task: UploadTask,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        throw PhotoPrismShareLinkError.uploadNotSupported
    }

    // MARK: - Private Helpers

    private func mapPhotoToAsset(_ photo: PhotoPrismPhoto) -> Asset? {
        let primaryFile = photo.Files?.first { $0.Primary == true } ?? photo.Files?.first
        let fileHash = primaryFile?.Hash ?? photo.Hash

        let assetType: AssetType = (photo.mediaType?.lowercased() == "video") ? .video : .image

        // Build EXIF from inline photo fields
        let hasExif = photo.CameraMake != nil || photo.CameraModel != nil ||
            photo.FNumber != nil || photo.Iso != nil || photo.FocalLength != nil

        let exif: AssetExif? = hasExif ? AssetExif(
            make: photo.CameraMake,
            model: photo.CameraModel,
            fNumber: photo.FNumber,
            focalLength: photo.FocalLength.map { Double($0) },
            iso: photo.Iso,
            exposureTime: photo.Exposure,
            width: primaryFile?.Width ?? photo.Width,
            height: primaryFile?.Height ?? photo.Height,
            fileSizeInBytes: primaryFile?.Size,
            latitude: (photo.Lat != nil && photo.Lat != 0) ? photo.Lat : nil,
            longitude: (photo.Lng != nil && photo.Lng != 0) ? photo.Lng : nil,
            city: nil,
            state: nil,
            country: (photo.Country != nil && photo.Country != "zz") ? photo.Country : nil,
            lensModel: photo.LensModel,
            orientation: nil,
            description: nil
        ) : nil

        var providerData: [String: String] = [:]
        providerData["uid"] = photo.UID
        providerData["fileHash"] = fileHash
        if let fileName = primaryFile?.Name {
            providerData["filename"] = fileName
        }

        return Asset(
            id: fileHash,
            type: assetType,
            originalFileName: primaryFile?.Name ?? photo.Title ?? photo.UID,
            createdAt: photo.TakenAtLocal ?? photo.TakenAt,
            duration: nil,
            thumbhash: nil,
            width: primaryFile?.Width ?? photo.Width,
            height: primaryFile?.Height ?? photo.Height,
            exif: exif,
            providerData: providerData
        )
    }
}

// MARK: - PhotoPrismPhoto helper

extension PhotoPrismPhoto {
    /// Hash of the primary file (used for thumbnails)
    var primaryFileHash: String {
        let primary = Files?.first { $0.Primary == true }
        return primary?.Hash ?? Hash
    }
}
