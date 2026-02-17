//
//  ShareLinkProvider.swift
//  OmniAlbum
//
//  Protocol that each photo service provider must conform to.
//  Encapsulates URL parsing, API calls, URL building, and uploads.
//

import Foundation

/// Parsed share link data returned by a provider
struct ParsedShareLinkResult {
    let baseURL: String
    let key: String?
    let slug: String?
    let token: String?
}

/// Lightweight info about a shared link (used when adding an album)
struct SharedLinkInfo: Sendable {
    let linkId: String
    let albumId: String
    let albumName: String
    let thumbnailAssetId: String?
    let assetCount: Int
    let shareKey: String
    let allowUpload: Bool
    let allowDownload: Bool
    let showMetadata: Bool
}

/// Variant of an asset to fetch (thumbnail, preview, or original)
enum AssetVariant: Sendable {
    case thumbnail
    case preview
    case original
}

/// Protocol that all photo service providers must implement
protocol ShareLinkProvider: Sendable {
    var providerType: PhotoProvider { get }

    /// Whether this provider requires client-side decryption for images
    var requiresClientDecryption: Bool { get }

    /// Whether this provider can handle the given URL string
    func canHandle(urlString: String) -> Bool

    /// Parse a share link URL into its components
    func parseShareLink(_ urlString: String) throws -> ParsedShareLinkResult

    /// Fetch metadata about a shared link (used when adding an album)
    func fetchSharedLinkInfo(
        baseURL: String,
        key: String?,
        slug: String?,
        token: String?,
        password: String?
    ) async throws -> SharedLinkInfo

    /// Fetch full album detail with all assets
    func fetchAlbumDetail(
        baseURL: String,
        albumId: String,
        shareKey: String,
        password: String?
    ) async throws -> AlbumDetail

    /// Build a thumbnail URL for an asset
    func thumbnailURL(baseURL: String, assetId: String, shareKey: String) -> URL?

    /// Build a preview (high-res) URL for an asset
    func previewURL(baseURL: String, asset: Asset, shareKey: String) -> URL?

    /// Build a URL to download the original file
    func originalURL(baseURL: String, asset: Asset, shareKey: String) -> URL?

    /// Build a video playback URL for streaming
    func videoPlaybackURL(baseURL: String, asset: Asset, shareKey: String) -> URL?

    /// Upload an asset to the provider
    func uploadAsset(
        task: UploadTask,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> String

    /// Fetch decrypted image/video data for providers that need client-side decryption
    func fetchDecryptedData(
        baseURL: String,
        asset: Asset,
        shareKey: String,
        variant: AssetVariant
    ) async throws -> Data
}

// MARK: - Default implementations

extension ShareLinkProvider {
    var requiresClientDecryption: Bool { false }

    func fetchDecryptedData(
        baseURL: String,
        asset: Asset,
        shareKey: String,
        variant: AssetVariant
    ) async throws -> Data {
        throw ProviderError.decryptionNotSupported
    }
}

enum ProviderError: LocalizedError {
    case decryptionNotSupported

    var errorDescription: String? {
        switch self {
        case .decryptionNotSupported:
            return "This provider does not support client-side decryption."
        }
    }
}
