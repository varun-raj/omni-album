//
//  EnteProvider.swift
//  immich-share
//
//  ShareLinkProvider implementation for Ente Photos.
//  Ente uses end-to-end encryption: all media is encrypted server-side and
//  must be decrypted client-side using a key embedded in the URL fragment.
//
//  Share link format: https://albums.ente.io/?t=TOKEN#BASE58_COLLECTION_KEY
//  Composite shareKey: "{accessToken}|{base58CollectionKey}"
//

import Foundation

struct EnteProvider: ShareLinkProvider {

    let providerType: PhotoProvider = .ente
    let requiresClientDecryption: Bool = true

    // MARK: - URL Handling

    func canHandle(urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let host = url.host?.lowercased() ?? ""
        return host == "albums.ente.io" || host.hasSuffix(".ente.io")
    }

    func parseShareLink(_ urlString: String) throws -> ParsedShareLinkResult {
        guard let url = URL(string: urlString) else {
            throw EnteServiceError.invalidBaseURL
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let accessToken = components?.queryItems?.first(where: { $0.name == "t" })?.value,
              !accessToken.isEmpty else {
            throw EnteServiceError.invalidBaseURL
        }

        guard let fragment = url.fragment, !fragment.isEmpty else {
            throw EnteServiceError.invalidBaseURL
        }

        return ParsedShareLinkResult(
            baseURL: "https://api.ente.io",
            key: fragment,
            slug: nil,
            token: accessToken
        )
    }

    // MARK: - Fetching

    func fetchSharedLinkInfo(
        baseURL: String,
        key: String?,
        slug: String?,
        token: String?,
        password: String?
    ) async throws -> SharedLinkInfo {
        guard let accessToken = token, let base58Key = key else {
            throw EnteServiceError.invalidBaseURL
        }

        guard let collectionKeyData = EnteCrypto.decodeBase58(base58Key) else {
            throw EnteServiceError.decryptionFailed
        }

        let collection = try await EnteService.fetchCollectionInfo(accessToken: accessToken)
        let albumName = decryptCollectionName(collection: collection, collectionKey: collectionKeyData) ?? "Ente Album"

        let files = try await EnteService.fetchFiles(accessToken: accessToken)
        let activeFiles = files.filter { $0.isDeleted != true }

        let coverFileId = activeFiles.first.map { String($0.id) }

        // Decrypt and cache cover thumbnail if available
        if let firstFile = activeFiles.first {
            let fileKey = decryptFileKey(file: firstFile, collectionKey: collectionKeyData)
            if let fileKey = fileKey {
                try? await downloadAndCacheThumbnail(
                    file: firstFile,
                    fileKey: fileKey,
                    accessToken: accessToken,
                    cacheDir: accessToken
                )
            }
        }

        let compositeShareKey = "\(accessToken)|\(base58Key)"

        return SharedLinkInfo(
            linkId: String(collection.id),
            albumId: String(collection.id),
            albumName: albumName,
            thumbnailAssetId: coverFileId,
            assetCount: activeFiles.count,
            shareKey: compositeShareKey,
            allowUpload: false,
            allowDownload: collection.publicURLs?.first?.enableDownload ?? true,
            showMetadata: true
        )
    }

    func fetchAlbumDetail(
        baseURL: String,
        albumId: String,
        shareKey: String,
        password: String?
    ) async throws -> AlbumDetail {
        let (accessToken, collectionKeyData) = try parseCompositeShareKey(shareKey)

        let collection = try await EnteService.fetchCollectionInfo(accessToken: accessToken)
        let albumName = decryptCollectionName(collection: collection, collectionKey: collectionKeyData) ?? "Ente Album"

        let files = try await EnteService.fetchFiles(accessToken: accessToken)
        let activeFiles = files.filter { $0.isDeleted != true }

        // Build assets from decrypted metadata (no thumbnail downloads here)
        var assets: [Asset] = []
        var thumbnailWork: [(EnteFile, Data)] = []

        for file in activeFiles {
            guard let fileKey = decryptFileKey(file: file, collectionKey: collectionKeyData) else {
                continue
            }

            let metadata = decryptFileMetadata(file: file, fileKey: fileKey)
            let fileName = metadata?.title ?? "IMG_\(file.id).jpg"
            let assetType = guessAssetType(fileName: fileName, fileType: metadata?.fileType)

            let createdAt: String?
            if let creationTime = metadata?.creationTime {
                let date = Date(timeIntervalSince1970: TimeInterval(creationTime) / 1_000_000)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                createdAt = formatter.string(from: date)
            } else {
                createdAt = nil
            }

            let providerData: [String: String] = [
                "fileId": String(file.id),
                "fileKey": fileKey.base64EncodedString(),
                "fileDecryptionHeader": file.file.decryptionHeader,
                "thumbDecryptionHeader": file.thumbnail.decryptionHeader,
            ]

            let exif: AssetExif?
            if metadata?.latitude != nil || metadata?.longitude != nil || metadata?.w != nil {
                exif = AssetExif(
                    make: nil, model: nil, fNumber: nil, focalLength: nil,
                    iso: nil, exposureTime: nil,
                    width: metadata?.w, height: metadata?.h,
                    fileSizeInBytes: file.info?.fileSize,
                    latitude: metadata?.latitude, longitude: metadata?.longitude,
                    city: nil, state: nil, country: nil,
                    lensModel: nil, orientation: nil, description: nil
                )
            } else {
                exif = file.info?.fileSize != nil ? AssetExif(
                    make: nil, model: nil, fNumber: nil, focalLength: nil,
                    iso: nil, exposureTime: nil, width: nil, height: nil,
                    fileSizeInBytes: file.info?.fileSize,
                    latitude: nil, longitude: nil,
                    city: nil, state: nil, country: nil,
                    lensModel: nil, orientation: nil, description: nil
                ) : nil
            }

            let asset = Asset(
                id: String(file.id),
                type: assetType,
                originalFileName: fileName,
                createdAt: createdAt,
                duration: nil,
                thumbhash: nil,
                width: metadata?.w,
                height: metadata?.h,
                exif: exif,
                providerData: providerData
            )
            assets.append(asset)
            thumbnailWork.append((file, fileKey))
        }

        // Download thumbnails concurrently (much faster than sequential)
        await withTaskGroup(of: Void.self) { group in
            for (file, fileKey) in thumbnailWork {
                group.addTask {
                    try? await downloadAndCacheThumbnail(
                        file: file,
                        fileKey: fileKey,
                        accessToken: accessToken,
                        cacheDir: accessToken
                    )
                }
            }
        }

        let now = ISO8601DateFormatter().string(from: Date())
        return AlbumDetail(
            albumName: albumName,
            description: nil,
            thumbnailAssetId: activeFiles.first.map { String($0.id) },
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
        let cacheDir = extractCacheDir(from: shareKey)
        let path = thumbnailCachePath(cacheDir: cacheDir, fileId: assetId)
        if FileManager.default.fileExists(atPath: path.path) {
            return path
        }
        return nil
    }

    func previewURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        nil
    }

    func originalURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        nil
    }

    func videoPlaybackURL(baseURL: String, asset: Asset, shareKey: String) -> URL? {
        nil
    }

    func uploadAsset(
        task: UploadTask,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        throw EnteServiceError.invalidResponse
    }

    // MARK: - Client-Side Decryption

    func fetchDecryptedData(
        baseURL: String,
        asset: Asset,
        shareKey: String,
        variant: AssetVariant
    ) async throws -> Data {
        let (accessToken, _) = try parseCompositeShareKey(shareKey)

        guard let fileIdStr = asset.providerData?["fileId"],
              let fileId = Int64(fileIdStr),
              let fileKeyBase64 = asset.providerData?["fileKey"],
              let fileKey = Data(base64Encoded: fileKeyBase64) else {
            throw EnteServiceError.decryptionFailed
        }

        switch variant {
        case .thumbnail:
            guard let headerStr = asset.providerData?["thumbDecryptionHeader"],
                  let header = Data(base64Encoded: headerStr) else {
                throw EnteServiceError.decryptionFailed
            }
            let encrypted = try await EnteService.downloadThumbnail(fileId: fileId, accessToken: accessToken)
            guard let decrypted = EnteCrypto.decryptStream(encryptedData: encrypted, header: header, key: fileKey) else {
                throw EnteServiceError.decryptionFailed
            }
            return decrypted

        case .preview, .original:
            // Check disk cache first
            let cacheDir = extractCacheDir(from: shareKey)
            let cachePath = previewCachePath(cacheDir: cacheDir, fileId: fileIdStr)
            if let cached = try? Data(contentsOf: cachePath) {
                return cached
            }

            guard let headerStr = asset.providerData?["fileDecryptionHeader"],
                  let header = Data(base64Encoded: headerStr) else {
                throw EnteServiceError.decryptionFailed
            }
            let encrypted = try await EnteService.downloadFile(fileId: fileId, accessToken: accessToken)
            guard let decrypted = EnteCrypto.decryptStream(encryptedData: encrypted, header: header, key: fileKey) else {
                throw EnteServiceError.decryptionFailed
            }

            // Cache to disk for next time
            let dir = cachePath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? decrypted.write(to: cachePath)

            return decrypted
        }
    }

    // MARK: - Private Helpers

    private func parseCompositeShareKey(_ shareKey: String) throws -> (accessToken: String, collectionKey: Data) {
        let parts = shareKey.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else {
            throw EnteServiceError.invalidBaseURL
        }
        let accessToken = String(parts[0])
        let base58Key = String(parts[1])

        guard let collectionKeyData = EnteCrypto.decodeBase58(base58Key) else {
            throw EnteServiceError.decryptionFailed
        }

        return (accessToken, collectionKeyData)
    }

    /// Use the access token as the cache directory name — consistent between
    /// fetchAlbumDetail (which writes) and thumbnailURL (which reads).
    private func extractCacheDir(from shareKey: String) -> String {
        let parts = shareKey.split(separator: "|", maxSplits: 1)
        return String(parts.first ?? "unknown")
    }

    private func decryptCollectionName(collection: EnteCollection, collectionKey: Data) -> String? {
        guard let encryptedName = collection.encryptedName,
              let nonceStr = collection.nameDecryptionNonce,
              let encryptedData = Data(base64Encoded: encryptedName),
              let nonce = Data(base64Encoded: nonceStr) else {
            return nil
        }

        guard let decrypted = EnteCrypto.decryptSecretBox(
            ciphertext: encryptedData,
            nonce: nonce,
            key: collectionKey
        ) else {
            return nil
        }

        return String(data: decrypted, encoding: .utf8)
    }

    private func decryptFileKey(file: EnteFile, collectionKey: Data) -> Data? {
        guard let encryptedKey = Data(base64Encoded: file.encryptedKey),
              let nonce = Data(base64Encoded: file.keyDecryptionNonce) else {
            return nil
        }

        return EnteCrypto.decryptSecretBox(
            ciphertext: encryptedKey,
            nonce: nonce,
            key: collectionKey
        )
    }

    private func decryptFileMetadata(file: EnteFile, fileKey: Data) -> EnteDecryptedMetadata? {
        guard let encryptedData = Data(base64Encoded: file.metadata.encryptedData),
              let header = Data(base64Encoded: file.metadata.decryptionHeader) else {
            return nil
        }

        guard let decrypted = EnteCrypto.decryptStream(
            encryptedData: encryptedData,
            header: header,
            key: fileKey
        ) else {
            return nil
        }

        return try? JSONDecoder().decode(EnteDecryptedMetadata.self, from: decrypted)
    }
}

// MARK: - Thumbnail caching (nonisolated free functions for use from Task.detached)

private func downloadAndCacheThumbnail(
    file: EnteFile,
    fileKey: Data,
    accessToken: String,
    cacheDir: String
) async throws {
    let cachePath = thumbnailCachePath(cacheDir: cacheDir, fileId: String(file.id))

    // Skip if already cached
    if FileManager.default.fileExists(atPath: cachePath.path) {
        return
    }

    guard let header = Data(base64Encoded: file.thumbnail.decryptionHeader) else {
        return
    }

    let encrypted = try await EnteService.downloadThumbnail(fileId: file.id, accessToken: accessToken)
    guard let decrypted = EnteCrypto.decryptStream(encryptedData: encrypted, header: header, key: fileKey) else {
        return
    }

    // Ensure directory exists
    let dir = cachePath.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    try decrypted.write(to: cachePath)
}

private func previewCachePath(cacheDir: String, fileId: String) -> URL {
    let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    return cachesDir
        .appendingPathComponent("ente-previews")
        .appendingPathComponent(cacheDir)
        .appendingPathComponent("\(fileId)")
}

private func thumbnailCachePath(cacheDir: String, fileId: String) -> URL {
    let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    return cachesDir
        .appendingPathComponent("ente-thumbs")
        .appendingPathComponent(cacheDir)
        .appendingPathComponent("\(fileId).jpg")
}

private func guessAssetType(fileName: String, fileType: Int?) -> AssetType {
    if let ft = fileType {
        return ft == 1 ? .video : .image
    }
    let ext = (fileName as NSString).pathExtension.lowercased()
    let videoExtensions = ["mp4", "mov", "avi", "mkv", "webm", "m4v"]
    return videoExtensions.contains(ext) ? .video : .image
}
