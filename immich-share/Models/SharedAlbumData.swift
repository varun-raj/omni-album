//
//  SharedAlbumData.swift
//  immich-share
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
}

enum SharedAlbumData {
    static let appGroupId = "group.com.skcript.immich-share"
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
                assetCount: album.assetCount
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
        var comp = URLComponents(string: entry.baseURL)
        comp?.path = "/api/assets/\(assetId)/thumbnail"
        comp?.queryItems = [URLQueryItem(name: "key", value: entry.shareKey)]
        return comp?.url
    }
}
