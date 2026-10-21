//
//  LocalAlbumsService.swift
//  OmniAlbum
//
//  Local JSON storage for albums - provides instant loading before CloudKit sync.
//

import Foundation

/// Codable version of DisplayAlbum for JSON storage
struct StoredAlbum: Codable, Identifiable {
    let id: String
    let albumName: String
    let albumThumbnailAssetId: String?
    let baseURL: String
    let shareKey: String
    let albumId: String
    let assetCount: Int?
    let allowUpload: Bool
    let allowDownload: Bool
    let showMetadata: Bool
    let password: String?  // legacy: only decoded, for migration into PasswordStore; never encoded
    let provider: String
    let createdAt: Date

    // Custom decoding to handle missing fields in older stored data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        albumName = try container.decode(String.self, forKey: .albumName)
        albumThumbnailAssetId = try container.decodeIfPresent(String.self, forKey: .albumThumbnailAssetId)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        shareKey = try container.decode(String.self, forKey: .shareKey)
        albumId = try container.decode(String.self, forKey: .albumId)
        assetCount = try container.decodeIfPresent(Int.self, forKey: .assetCount)
        allowUpload = try container.decodeIfPresent(Bool.self, forKey: .allowUpload) ?? false
        allowDownload = try container.decodeIfPresent(Bool.self, forKey: .allowDownload) ?? true
        showMetadata = try container.decodeIfPresent(Bool.self, forKey: .showMetadata) ?? true
        password = try container.decodeIfPresent(String.self, forKey: .password)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "immich"
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    init(from displayAlbum: DisplayAlbum, createdAt: Date = Date()) {
        self.id = displayAlbum.id
        self.albumName = displayAlbum.albumName
        self.albumThumbnailAssetId = displayAlbum.albumThumbnailAssetId
        self.baseURL = displayAlbum.baseURL
        self.shareKey = displayAlbum.shareKey
        self.albumId = displayAlbum.albumId
        self.assetCount = displayAlbum.assetCount
        self.allowUpload = displayAlbum.allowUpload
        self.allowDownload = displayAlbum.allowDownload
        self.showMetadata = displayAlbum.showMetadata
        self.password = displayAlbum.password
        self.provider = displayAlbum.provider.rawValue
        self.createdAt = createdAt
    }

    func toDisplayAlbum() -> DisplayAlbum {
        DisplayAlbum(
            id: id,
            albumName: albumName,
            albumThumbnailAssetId: albumThumbnailAssetId,
            baseURL: baseURL,
            shareKey: shareKey,
            albumId: albumId,
            assetCount: assetCount,
            allowUpload: allowUpload,
            allowDownload: allowDownload,
            showMetadata: showMetadata,
            password: password ?? PasswordStore.get(baseURL: baseURL, shareKey: shareKey, legacyAlbumId: albumId),
            provider: PhotoProvider(rawValue: provider) ?? .immich
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(albumName, forKey: .albumName)
        try c.encodeIfPresent(albumThumbnailAssetId, forKey: .albumThumbnailAssetId)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(shareKey, forKey: .shareKey)
        try c.encode(albumId, forKey: .albumId)
        try c.encodeIfPresent(assetCount, forKey: .assetCount)
        try c.encode(allowUpload, forKey: .allowUpload)
        try c.encode(allowDownload, forKey: .allowDownload)
        try c.encode(showMetadata, forKey: .showMetadata)
        try c.encode(provider, forKey: .provider)
        try c.encode(createdAt, forKey: .createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, albumName, albumThumbnailAssetId, baseURL, shareKey
        case albumId, assetCount, allowUpload, allowDownload, showMetadata
        case password, provider, createdAt
    }
}

/// Local storage service using JSON file in documents directory
final class LocalAlbumsService {
    private let fileName = "albums.json"

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    /// Load albums from local JSON file
    func loadAlbums() -> [DisplayAlbum] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let stored = try JSONDecoder().decode([StoredAlbum].self, from: data)
            migratePasswords(stored)
            // Sort by createdAt descending (newest first)
            let sorted = stored.sorted { $0.createdAt > $1.createdAt }
            return sorted.map { $0.toDisplayAlbum() }
        } catch {
            print("LocalAlbumsService: Failed to load albums: \(error)")
            return []
        }
    }

    /// Save albums to local JSON file
    func saveAlbums(_ albums: [DisplayAlbum]) {
        // Preserve existing createdAt dates if available
        let existingAlbums = loadStoredAlbums()
        let existingDates = Dictionary(existingAlbums.map { ($0.id, $0.createdAt) }, uniquingKeysWith: { first, _ in first })

        let stored = albums.map { album in
            StoredAlbum(
                from: album,
                createdAt: existingDates[album.id] ?? Date()
            )
        }

        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("LocalAlbumsService: Failed to save albums: \(error)")
        }
    }

    /// Add a single album to local storage
    func addAlbum(_ album: DisplayAlbum) {
        var albums = loadStoredAlbums()

        // Don't add duplicates
        if !albums.contains(where: { $0.id == album.id }) {
            albums.insert(StoredAlbum(from: album), at: 0) // Add to beginning (newest)
            saveStoredAlbums(albums)
        }
    }

    /// Delete an album from local storage
    func deleteAlbum(id: String) {
        var albums = loadStoredAlbums()
        if let removed = albums.first(where: { $0.id == id }) { PasswordStore.set(nil, baseURL: removed.baseURL, shareKey: removed.shareKey) }
        albums.removeAll { $0.id == id }
        saveStoredAlbums(albums)
    }

    /// Merge CloudKit albums with local albums
    /// CloudKit wins for albums in both; local-only albums are kept (their CloudKit save may have failed).
    /// ponytail: no tombstones, so an album deleted on another device reappears here until deleted again.
    func mergeWithCloudKit(_ cloudKitAlbums: [DisplayAlbum]) -> [DisplayAlbum] {
        let localAlbums = loadStoredAlbums()
        let localDates = Dictionary(localAlbums.map { ($0.id, $0.createdAt) }, uniquingKeysWith: { first, _ in first })

        // Use CloudKit albums as source of truth, but preserve local creation dates
        for album in cloudKitAlbums where album.password != nil { PasswordStore.set(album.password, baseURL: album.baseURL, shareKey: album.shareKey) }
        let cloudIds = Set(cloudKitAlbums.map(\.id))
        let merged = cloudKitAlbums.map { album in
            StoredAlbum(
                from: album,
                createdAt: localDates[album.id] ?? Date()
            )
        } + localAlbums.filter { !cloudIds.contains($0.id) }

        // Sort by createdAt descending
        let sorted = merged.sorted { $0.createdAt > $1.createdAt }

        // Save merged data locally
        saveStoredAlbums(sorted)

        return sorted.map { $0.toDisplayAlbum() }
    }

    // MARK: - Private helpers

    /// Move passwords from older albums.json files into the Keychain, then rewrite the file without them.
    private func migratePasswords(_ stored: [StoredAlbum]) {
        let legacy = stored.filter { $0.password != nil }
        guard !legacy.isEmpty else { return }
        for album in legacy { PasswordStore.set(album.password, baseURL: album.baseURL, shareKey: album.shareKey) }
        saveStoredAlbums(stored)
    }

    private func loadStoredAlbums() -> [StoredAlbum] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let stored = try JSONDecoder().decode([StoredAlbum].self, from: data)
            migratePasswords(stored)
            return stored
        } catch {
            return []
        }
    }

    private func saveStoredAlbums(_ albums: [StoredAlbum]) {
        do {
            let data = try JSONEncoder().encode(albums)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("LocalAlbumsService: Failed to save albums: \(error)")
        }
    }
}
