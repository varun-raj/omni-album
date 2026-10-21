//
//  AssetSource.swift
//  OmniAlbum
//
//  What the grid and viewer need from wherever assets come from: a shared-link album, or a synced
//  Immich account. Keeps the viewer independent of any one provider.
//

import Foundation

@MainActor
protocol AssetSource: AnyObject {
    var allowDownload: Bool { get }
    var showMetadata: Bool { get }
    /// Providers whose media is encrypted at rest (Ente) decrypt on device.
    var requiresDecryption: Bool { get }
    /// Request headers for image and video loads (an account's bearer token); nil for share links.
    var imageHeaders: [String: String]? { get }
    /// Cache namespace, so signed-in users never share cached images.
    var imageCacheScope: String? { get }

    func thumbnailURL(for asset: Asset) -> URL?
    func previewURL(for asset: Asset) -> URL?
    func originalURL(for asset: Asset) -> URL?
    func videoPlaybackURL(for asset: Asset) -> URL?
    func loadImageData(for asset: Asset, variant: AssetVariant) async throws -> Data?
    /// EXIF kept outside the `Asset` value (account assets read it from the local database).
    func exif(for asset: Asset) async -> AssetExif?
}

extension AssetSource {
    var requiresDecryption: Bool { false }
    var imageHeaders: [String: String]? { nil }
    var imageCacheScope: String? { nil }
    func loadImageData(for asset: Asset, variant: AssetVariant) async throws -> Data? { nil }
    func exif(for asset: Asset) async -> AssetExif? { nil }
    func isVideo(_ asset: Asset) -> Bool { asset.type == .video }
}

extension Asset {
    func withExif(_ exif: AssetExif?) -> Asset {
        Asset(id: id, type: type, originalFileName: originalFileName, createdAt: createdAt, duration: duration,
              thumbhash: thumbhash, width: width, height: height, exif: exif, providerData: providerData)
    }
}
