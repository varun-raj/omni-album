//
//  SharedAlbumData.swift
//  OmniAlbum
//
//  Shared data model for passing album info to the widget extension via App Groups.
//

import Foundation

/// Lightweight album data for widget display, stored in shared App Group container
struct SharedAlbumEntry: Codable {
    let albumId: String
    let albumName: String
    let baseURL: String
    let shareKey: String
    let thumbnailAssetId: String?
    let assetCount: Int?
    let provider: String?  // Defaults to "immich" for backward compat
}

enum SharedAlbumData {
    static let appGroupId = "group.com.skcript.omnialbum"
    private static let albumsKey = "widgetAlbums"

    /// Save albums to shared UserDefaults for widget access
    static func saveAlbums(_ albums: [DisplayAlbum]) {
        let entries = albums.prefix(6).map { album in
            SharedAlbumEntry(
                albumId: album.albumId,
                albumName: album.albumName,
                baseURL: album.baseURL,
                shareKey: album.shareKey,
                thumbnailAssetId: album.albumThumbnailAssetId,
                assetCount: album.assetCount,
                provider: album.provider.rawValue
            )
        }

        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: albumsKey)
        }
    }

    /// Load albums from shared UserDefaults (for widget)
    static func loadAlbums() -> [SharedAlbumEntry] {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: albumsKey),
              let entries = try? JSONDecoder().decode([SharedAlbumEntry].self, from: data) else {
            return []
        }
        return entries
    }

    /// Build a thumbnail URL for a shared album entry
    static func thumbnailURL(for entry: SharedAlbumEntry) -> URL? {
        guard let assetId = entry.thumbnailAssetId, !assetId.isEmpty else { return nil }
        let providerType = PhotoProvider(rawValue: entry.provider ?? "immich") ?? .immich
        if let provider = ProviderRegistry.shared.provider(for: providerType) {
            return provider.thumbnailURL(baseURL: entry.baseURL, assetId: assetId, shareKey: entry.shareKey)
        }
        return nil
    }
}

// MARK: - Shared Asset Pool (for Random Photo Widget)

/// Cached pool of image asset IDs for a single album, stored in App Group for widget access
struct SharedAssetPool: Codable {
    let albumId: String
    let provider: String
    let baseURL: String
    let shareKey: String
    let albumName: String
    let assetIds: [String]  // Up to 50 image asset IDs
    let assetDates: [String]?  // Parallel array of ISO8601 date strings (optional for backward compat)
    let lastUpdated: Date
}

extension SharedAlbumData {
    private static let assetPoolsKey = "widgetAssetPools"

    /// Save asset pools to shared UserDefaults
    static func saveAssetPools(_ pools: [SharedAssetPool]) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        if let data = try? JSONEncoder().encode(pools) {
            defaults.set(data, forKey: assetPoolsKey)
        }
    }

    /// Load asset pools from shared UserDefaults
    static func loadAssetPools() -> [SharedAssetPool] {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: assetPoolsKey),
              let pools = try? JSONDecoder().decode([SharedAssetPool].self, from: data) else {
            return []
        }
        return pools
    }

    /// Update or insert the asset pool for a given album
    static func updateAssetPool(albumId: String, provider: String, baseURL: String, shareKey: String, albumName: String, assetIds: [String], assetDates: [String] = []) {
        var pools = loadAssetPools()
        pools.removeAll { $0.albumId == albumId }
        let pool = SharedAssetPool(
            albumId: albumId,
            provider: provider,
            baseURL: baseURL,
            shareKey: shareKey,
            albumName: albumName,
            assetIds: Array(assetIds.prefix(50)),
            assetDates: assetDates.isEmpty ? nil : Array(assetDates.prefix(50)),
            lastUpdated: Date()
        )
        pools.append(pool)
        saveAssetPools(pools)
    }
}
