//
//  NextcloudProvider.swift
//  OmniAlbum
//
//  Concrete ShareLinkProvider for Nextcloud Photos public albums.
//  Wraps NextcloudService for WebDAV communication.
//
//  Share link format: https://cloud.example.com/apps/photos/public/{TOKEN}
//  WebDAV endpoint:   /remote.php/dav/photospublic/{TOKEN}
//  Preview endpoint:  /apps/photos/api/v1/publicPreview/{fileId}?x=W&y=H&token=TOKEN
//

import Foundation
import Photos

// MARK: - Link Parsing Error

enum NextcloudShareLinkError: LocalizedError {
    case notAValidURL(String)
    case missingPhotosPath
    case missingToken

    var errorDescription: String? {
        switch self {
        case .notAValidURL(let s): return "Not a valid URL: \(s)"
        case .missingPhotosPath: return "URL must be a Nextcloud Photos public album link (path contains /apps/photos/public/)."
        case .missingToken: return "Share link must include an album token."
        }
    }
}

// MARK: - Provider

final class NextcloudProvider: ShareLinkProvider, @unchecked Sendable {
    let providerType: PhotoProvider = .nextcloud

    private let service = NextcloudService()

    // MARK: - Link Handling

    func canHandle(urlString: String) -> Bool {
        urlString.contains("/apps/photos/public/")
    }

    func parseShareLink(_ urlString: String) throws -> ParsedShareLinkResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = trimmed
        if !s.contains("://") { s = "https://" + s }

        guard let url = URL(string: s), let host = url.host else {
            throw NextcloudShareLinkError.notAValidURL(trimmed)
        }

        let path = url.path
        guard path.contains("/apps/photos/public/") else {
            throw NextcloudShareLinkError.missingPhotosPath
        }

        // Extract base URL
        let scheme = url.scheme ?? "https"
        var base = "\(scheme)://\(host)"
        if let port = url.port, (scheme == "https" && port != 443) || (scheme == "http" && port != 80) {
            base += ":\(port)"
        }

        // Extract token: last path component after /apps/photos/public/
        let pathParts = path.split(separator: "/")
        guard let publicIndex = pathParts.firstIndex(of: "public"),
              publicIndex + 1 < pathParts.count else {
            throw NextcloudShareLinkError.missingToken
        }
        let token = String(pathParts[publicIndex + 1])

        guard !token.isEmpty else {
            throw NextcloudShareLinkError.missingToken
        }

        return ParsedShareLinkResult(
            baseURL: base,
            key: token,
            slug: nil,
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
        guard let token = token ?? key, !token.isEmpty else {
            throw NextcloudShareLinkError.missingToken
        }

        // Fetch album metadata and file list
        let albumInfo = try await service.fetchAlbumInfo(baseURL: baseURL, token: token, password: password)
        let files = try await service.listFiles(baseURL: baseURL, token: token, password: password)

        let albumName = albumInfo.originalName ?? albumInfo.displayName ?? "Shared Album"
        let assetCount = albumInfo.nbItems ?? files.count
        let thumbnailFileId = files.first?.fileId

        // Check permissions for upload capability
        let permissions = albumInfo.permissions ?? ""
        let allowUpload = permissions.contains("C") || permissions.contains("N") || permissions.contains("W")

        return SharedLinkInfo(
            linkId: token,
            albumId: token,
            albumName: albumName,
            thumbnailAssetId: thumbnailFileId,
            assetCount: assetCount,
            shareKey: token,
            allowUpload: allowUpload,
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
        let albumInfo = try await service.fetchAlbumInfo(baseURL: baseURL, token: shareKey, password: password)
        let files = try await service.listFiles(baseURL: baseURL, token: shareKey, password: password)

        let assets = files.compactMap { file -> Asset? in
            guard let fileId = file.fileId else { return nil }

            let assetType: AssetType = file.isVideo ? .video : .image
            let fileName = file.fileName ?? "unknown"

            // Convert lastModified to ISO8601-like string for consistency
            let createdAt = file.originalDateTime ?? file.lastModified

            var providerData: [String: String] = [:]
            providerData["filename"] = fileName
            if let ct = file.contentType {
                providerData["contentType"] = ct
            }
            // Store the full href for building download URLs
            if let hrefFileName = file.href.split(separator: "/").last {
                providerData["hrefName"] = String(hrefFileName).removingPercentEncoding ?? String(hrefFileName)
            }

            return Asset(
                id: fileId,
                type: assetType,
                originalFileName: fileName,
                createdAt: createdAt,
                duration: nil,
                thumbhash: nil,
                width: file.width,
                height: file.height,
                exif: file.contentLength.map { size in
                    AssetExif(
                        make: nil, model: nil, fNumber: nil, focalLength: nil,
                        iso: nil, exposureTime: nil, width: file.width, height: file.height,
                        fileSizeInBytes: size, latitude: nil, longitude: nil,
                        city: nil, state: nil, country: nil, lensModel: nil,
                        orientation: nil, description: nil
                    )
                },
                providerData: providerData.isEmpty ? nil : providerData
            )
        }

        let albumName = albumInfo.originalName ?? albumInfo.displayName ?? "Shared Album"
        let now = ISO8601DateFormatter().string(from: Date())

        return AlbumDetail(
            albumName: albumName,
            description: albumInfo.location,
            thumbnailAssetId: files.first?.fileId,
            createdAt: now,
            updatedAt: now,
            ownerName: nil,
            ownerEmail: nil,
            ownerAvatarColor: nil,
            assetCount: albumInfo.nbItems ?? assets.count,
            assets: assets,
            sharedUsers: []
        )
    }

    // MARK: - URL Builders

    func thumbnailURL(baseURL: String, assetId: String, shareKey: String) -> URL? {
        // /apps/photos/api/v1/publicPreview/{fileId}?x=256&y=256&token={TOKEN}
        var comp = URLComponents(string: baseURL)
        comp?.path = "/apps/photos/api/v1/publicPreview/\(assetId)"
        comp?.queryItems = [
            URLQueryItem(name: "x", value: "256"),
            URLQueryItem(name: "y", value: "256"),
            URLQueryItem(name: "token", value: shareKey)
        ]
        return comp?.url
    }

    func previewURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        // /apps/photos/api/v1/publicPreview/{fileId}?x=2048&y=2048&token={TOKEN}
        var comp = URLComponents(string: baseURL)
        comp?.path = "/apps/photos/api/v1/publicPreview/\(asset.id)"
        comp?.queryItems = [
            URLQueryItem(name: "x", value: "2048"),
            URLQueryItem(name: "y", value: "2048"),
            URLQueryItem(name: "token", value: shareKey)
        ]
        return comp?.url
    }

    func originalURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        // /remote.php/dav/photospublic/{TOKEN}/{fileId}-{fileName}
        // Embed Basic auth (token:) in the URL for downloads that need authentication
        guard let hrefName = asset.providerData?["hrefName"] ?? asset.providerData?["filename"] else {
            return nil
        }
        let encodedName = hrefName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? hrefName
        guard let baseComp = URLComponents(string: baseURL),
              let host = baseComp.host else { return nil }
        let scheme = baseComp.scheme ?? "https"
        var authBase = "\(scheme)://\(shareKey):@\(host)"
        if let port = baseComp.port {
            authBase += ":\(port)"
        }
        return URL(string: "\(authBase)/remote.php/dav/photospublic/\(shareKey)/\(encodedName)")
    }

    func videoPlaybackURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        guard asset.type == .video else { return nil }
        return originalURL(baseURL: baseURL, asset: asset, shareKey: shareKey)
    }

    // MARK: - Upload

    func uploadAsset(
        task: UploadTask,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        // Fetch the PHAsset
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [task.localAssetIdentifier],
            options: nil
        )

        guard let asset = fetchResult.firstObject else {
            throw NextcloudServiceError.invalidResponse
        }

        let exported = try await AssetFileExporter.export(asset)
        defer { try? FileManager.default.removeItem(at: exported.url) }

        try await service.uploadFile(
            baseURL: task.baseURL,
            token: task.shareKey,
            password: task.password,
            fileName: task.fileName,
            file: exported.url,
            progressHandler: progressHandler
        )

        // Nextcloud WebDAV PUT doesn't return an asset ID, use filename as identifier
        return task.fileName
    }
}
