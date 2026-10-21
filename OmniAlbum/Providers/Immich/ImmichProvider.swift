//
//  ImmichProvider.swift
//  OmniAlbum
//
//  Concrete ShareLinkProvider for Immich. Wraps existing ImmichShareService,
//  ImmichShareLink, and ImmichUploadService without modifying them.
//

import Foundation

final class ImmichProvider: ShareLinkProvider, @unchecked Sendable {
    let providerType: PhotoProvider = .immich

    private let shareService = ImmichShareService()
    private let uploadService = ImmichUploadService()

    func canHandle(urlString: String) -> Bool {
        urlString.contains("/share/")
    }

    func parseShareLink(_ urlString: String) throws -> ParsedShareLinkResult {
        let parsed = try ImmichShareLink.parse(urlString)
        return ParsedShareLinkResult(
            baseURL: parsed.baseURL,
            key: parsed.key,
            slug: parsed.slug,
            token: parsed.token
        )
    }

    func fetchSharedLinkInfo(
        baseURL: String,
        key: String?,
        slug: String?,
        token: String?,
        password: String?
    ) async throws -> SharedLinkInfo {
        let response = try await shareService.fetchSharedLink(
            baseURL: baseURL,
            key: key,
            slug: slug,
            token: token,
            password: password
        )
        guard let album = response.album else {
            throw ImmichShareServiceError.invalidResponse
        }
        return SharedLinkInfo(
            linkId: response.id,
            albumId: album.id,
            albumName: album.albumName,
            thumbnailAssetId: album.albumThumbnailAssetId,
            assetCount: album.assetCount,
            shareKey: response.key,
            allowUpload: response.allowUpload,
            allowDownload: response.allowDownload,
            showMetadata: response.showMetadata
        )
    }

    func fetchAlbumDetail(
        baseURL: String,
        albumId: String,
        shareKey: String,
        password: String?
    ) async throws -> AlbumDetail {
        let response = try await shareService.fetchAlbumWithAssets(
            baseURL: baseURL,
            albumId: albumId,
            shareKey: shareKey,
            password: password
        )
        return mapAlbumResponse(response)
    }

    func thumbnailURL(baseURL: String, assetId: String, shareKey: String) -> URL? {
        var comp = URLComponents(string: baseURL)
        comp?.path += "/api/assets/\(assetId)/thumbnail"
        comp?.queryItems = [URLQueryItem(name: "key", value: shareKey)]
        return comp?.url
    }

    func previewURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        var comp = URLComponents(string: baseURL)
        comp?.path += "/api/assets/\(asset.id)/thumbnail"
        comp?.queryItems = [
            URLQueryItem(name: "key", value: shareKey),
            URLQueryItem(name: "size", value: "preview"),
            URLQueryItem(name: "edited", value: "true")
        ]
        return comp?.url
    }

    func originalURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        var comp = URLComponents(string: baseURL)
        comp?.path += "/api/assets/\(asset.id)/original"
        comp?.queryItems = [URLQueryItem(name: "key", value: shareKey)]
        return comp?.url
    }

    func videoPlaybackURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        guard asset.type == .video else { return nil }
        var comp = URLComponents(string: baseURL)
        comp?.path += "/api/assets/\(asset.id)/video/playback"
        var queryItems = [URLQueryItem(name: "key", value: shareKey)]
        if let checksum = asset.providerData?["checksum"] {
            queryItems.append(URLQueryItem(name: "c", value: checksum))
        }
        comp?.queryItems = queryItems
        return comp?.url
    }

    func uploadAsset(
        task: UploadTask,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        try await uploadService.uploadAsset(task: task, progressHandler: progressHandler)
    }

    // MARK: - Mapping helpers

    private func mapAlbumResponse(_ response: AlbumWithAssetsResponse) -> AlbumDetail {
        AlbumDetail(
            albumName: response.albumName,
            description: response.description,
            thumbnailAssetId: response.albumThumbnailAssetId,
            createdAt: response.createdAt,
            updatedAt: response.updatedAt,
            ownerName: response.owner.name,
            ownerEmail: response.owner.email,
            ownerAvatarColor: response.owner.avatarColor,
            assetCount: response.assetCount,
            assets: response.assets.map { mapAsset($0) },
            sharedUsers: response.albumUsers.compactMap { albumUser in
                guard let user = albumUser.user else { return nil }
                return AlbumSharedUser(
                    id: user.id,
                    name: user.name,
                    email: user.email,
                    role: albumUser.role,
                    avatarColor: user.avatarColor
                )
            }
        )
    }

    private func mapAsset(_ immichAsset: ImmichAsset) -> Asset {
        let assetType: AssetType = immichAsset.type.lowercased() == "video" ? .video : .image

        let exif: AssetExif? = immichAsset.exifInfo.map { e in
            AssetExif(
                make: e.make,
                model: e.model,
                fNumber: e.fNumber,
                focalLength: e.focalLength,
                iso: e.iso,
                exposureTime: e.exposureTime,
                width: e.exifImageWidth,
                height: e.exifImageHeight,
                fileSizeInBytes: e.fileSizeInByte,
                latitude: e.latitude,
                longitude: e.longitude,
                city: e.city,
                state: e.state,
                country: e.country,
                lensModel: e.lensModel,
                orientation: e.orientation,
                description: e.description
            )
        }

        var providerData: [String: String] = [:]
        if let checksum = immichAsset.checksum {
            providerData["checksum"] = checksum
        }
        if let mimeType = immichAsset.originalMimeType {
            providerData["originalMimeType"] = mimeType
        }

        return Asset(
            id: immichAsset.id,
            type: assetType,
            originalFileName: immichAsset.originalFileName,
            createdAt: immichAsset.fileCreatedAt ?? immichAsset.localDateTime ?? immichAsset.createdAt,
            duration: immichAsset.duration,
            thumbhash: immichAsset.thumbhash,
            width: immichAsset.width,
            height: immichAsset.height,
            exif: exif,
            providerData: providerData.isEmpty ? nil : providerData
        )
    }
}
