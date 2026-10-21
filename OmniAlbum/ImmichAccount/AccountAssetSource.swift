//
//  AccountAssetSource.swift
//  OmniAlbum
//
//  Feeds the shared grid and viewer from a synced Immich account: URLs for the account's server
//  (loaded with the bearer token) and EXIF from the local database.
//

import Foundation

@MainActor
final class AccountAssetSource: AssetSource {
    private let client: ImmichAccountClient
    private let store: LibraryStore

    init(client: ImmichAccountClient, store: LibraryStore) {
        self.client = client
        self.store = store
    }

    var allowDownload: Bool { true }
    var showMetadata: Bool { true }
    var imageHeaders: [String: String]? { client.authHeaders }
    var imageCacheScope: String? { client.cacheScope }

    func thumbnailURL(for asset: Asset) -> URL? { client.thumbnailURL(assetId: asset.id) }
    func previewURL(for asset: Asset) -> URL? { client.previewURL(assetId: asset.id) }
    func originalURL(for asset: Asset) -> URL? { client.originalURL(assetId: asset.id) }
    func videoPlaybackURL(for asset: Asset) -> URL? { client.videoPlaybackURL(assetId: asset.id) }

    /// From the local database if it was synced, otherwise fetched from the server for this one asset.
    func exif(for asset: Asset) async -> AssetExif? {
        guard let e = try? await store.exif(assetId: asset.id) else {
            return try? await client.fetchExif(assetId: asset.id)
        }
        return AssetExif(make: e.make, model: e.model, fNumber: e.fNumber, focalLength: e.focalLength, iso: e.iso,
                         exposureTime: e.exposureTime, width: e.exifImageWidth, height: e.exifImageHeight,
                         fileSizeInBytes: e.fileSizeInByte.map(Int64.init), latitude: e.latitude, longitude: e.longitude,
                         city: e.city, state: e.state, country: e.country, lensModel: e.lensModel,
                         orientation: e.orientation, description: e.description)
    }
}

extension LibraryAsset {
    /// The generic asset the grid and viewer use. Immich reports video length in milliseconds.
    var asAsset: Asset {
        Asset(id: id, type: isVideo ? .video : .image, originalFileName: fileName, createdAt: localDateTime,
              duration: duration.map(Self.clock), thumbhash: thumbhash, width: width, height: height, exif: nil, providerData: nil)
    }

    private static func clock(_ milliseconds: Int) -> String {
        let s = milliseconds / 1000
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
