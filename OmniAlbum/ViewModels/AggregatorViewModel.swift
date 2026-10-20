//
//  AggregatorViewModel.swift
//  OmniAlbum
//
//  Local-first album list: loads from local cache instantly, then syncs with CloudKit.
//

import Foundation
import Combine
import SwiftUI
import WidgetKit

extension Notification.Name {
    static let albumDataUpdated = Notification.Name("albumDataUpdated")
}

struct DisplayAlbum: Identifiable, Hashable, Sendable {
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
    let password: String?
    let provider: PhotoProvider

    init(
        id: String,
        albumName: String,
        albumThumbnailAssetId: String?,
        baseURL: String,
        shareKey: String,
        albumId: String,
        assetCount: Int?,
        allowUpload: Bool = false,
        allowDownload: Bool = true,
        showMetadata: Bool = true,
        password: String? = nil,
        provider: PhotoProvider = .immich
    ) {
        self.id = id
        self.albumName = albumName
        self.albumThumbnailAssetId = albumThumbnailAssetId
        self.baseURL = baseURL
        self.shareKey = shareKey
        self.albumId = albumId
        self.assetCount = assetCount
        self.allowUpload = allowUpload
        self.allowDownload = allowDownload
        self.showMetadata = showMetadata
        self.password = password
        self.provider = provider
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DisplayAlbum, rhs: DisplayAlbum) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class AggregatorViewModel: ObservableObject {
    @Published private(set) var albums: [DisplayAlbum] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSyncing = false
    @Published private(set) var errorMessage: String?

    private let cloudKitService = CloudKitAlbumsService()
    private let localService = LocalAlbumsService()
    private let spotlightService = SpotlightService.shared
    private var cancellables = Set<AnyCancellable>()

    /// Check if iCloud sync is enabled
    private var iCloudSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.iCloudSyncEnabled)
    }

    init() {
        // Listen for album data updates from detail view
        NotificationCenter.default.publisher(for: .albumDataUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let albumId = notification.userInfo?["albumId"] as? String,
                   let assetCount = notification.userInfo?["assetCount"] as? Int,
                   let thumbnailId = notification.userInfo?["thumbnailId"] as? String? {
                    self?.updateAlbumData(albumId: albumId, assetCount: assetCount, thumbnailId: thumbnailId)
                }
            }
            .store(in: &cancellables)

        // Load data asynchronously to not block UI
        Task {
            await loadData()
        }
    }

    /// Load albums from local cache, then sync with CloudKit
    private func loadData() async {
        isLoading = true

        // Load from local storage in background thread
        let localAlbums = await Task.detached { [localService] in
            localService.loadAlbums()
        }.value

        albums = localAlbums
        isLoading = false

        // Index albums in Spotlight
        spotlightService.indexAlbums(localAlbums)

        // Update widget data
        updateWidgetData(localAlbums)

        // Then sync with CloudKit
        await syncWithCloudKit()
    }

    /// Update album data from detail view
    func updateAlbumData(albumId: String, assetCount: Int, thumbnailId: String?) {
        guard let index = albums.firstIndex(where: { $0.albumId == albumId }) else { return }

        let oldAlbum = albums[index]
        let updatedAlbum = DisplayAlbum(
            id: oldAlbum.id,
            albumName: oldAlbum.albumName,
            albumThumbnailAssetId: thumbnailId ?? oldAlbum.albumThumbnailAssetId,
            baseURL: oldAlbum.baseURL,
            shareKey: oldAlbum.shareKey,
            albumId: oldAlbum.albumId,
            assetCount: assetCount,
            allowUpload: oldAlbum.allowUpload,
            allowDownload: oldAlbum.allowDownload,
            showMetadata: oldAlbum.showMetadata,
            password: oldAlbum.password,
            provider: oldAlbum.provider
        )

        albums[index] = updatedAlbum

        // Update local storage
        localService.saveAlbums(albums)

        // Also update CloudKit so the count syncs across devices
        if iCloudSyncEnabled {
            Task {
                do {
                    try await cloudKitService.save(updatedAlbum)
                } catch {
                    print("Failed to update CloudKit with album data: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Sync with CloudKit and merge with local data
    func syncWithCloudKit() async {
        // Skip CloudKit sync if disabled
        guard iCloudSyncEnabled else {
            print("iCloud sync is disabled, skipping CloudKit sync")
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let cloudKitAlbums = try await cloudKitService.fetchAll()

            // Push albums that never made it to CloudKit (offline add, failed save)
            let cloudIds = Set(cloudKitAlbums.map(\.id))
            for album in albums where !cloudIds.contains(album.id) {
                try? await cloudKitService.save(album)
            }

            // Merge CloudKit data with local (CloudKit is source of truth)
            let merged = localService.mergeWithCloudKit(cloudKitAlbums)

            // Only update if there are changes
            if merged.map({ $0.id }) != albums.map({ $0.id }) {
                albums = merged
            }

            // Re-index in Spotlight after sync
            spotlightService.indexAlbums(albums)

            // Update widget data
            updateWidgetData(albums)

            errorMessage = nil
        } catch {
            // Don't overwrite local data on sync failure
            // Just log the error - user can still use local data
            print("CloudKit sync failed: \(error.localizedDescription)")

            // Only show error if we have no local data
            if albums.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Force refresh from CloudKit
    func refresh() async {
        await syncWithCloudKit()
    }

    /// Thumbnail URL for an album's cover image, resolved via its provider
    static func thumbnailURL(for album: DisplayAlbum) -> URL? {
        guard let assetId = album.albumThumbnailAssetId, !assetId.isEmpty else { return nil }
        guard let provider = ProviderRegistry.shared.provider(for: album.provider) else { return nil }
        return provider.thumbnailURL(baseURL: album.baseURL, assetId: assetId, shareKey: album.shareKey)
    }

    func addAlbum(shareLinkURL: String, provider providerType: PhotoProvider, password: String? = nil) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            guard let provider = ProviderRegistry.shared.provider(for: providerType) else {
                errorMessage = "Unsupported provider."
                return
            }
            let parsed = try provider.parseShareLink(shareLinkURL)
            let info = try await provider.fetchSharedLinkInfo(
                baseURL: parsed.baseURL,
                key: parsed.key,
                slug: parsed.slug,
                token: parsed.token,
                password: password
            )
            let display = DisplayAlbum(
                id: info.linkId,
                albumName: info.albumName,
                albumThumbnailAssetId: info.thumbnailAssetId,
                baseURL: parsed.baseURL,
                shareKey: info.shareKey,
                albumId: info.albumId,
                assetCount: info.assetCount,
                allowUpload: info.allowUpload,
                allowDownload: info.allowDownload,
                showMetadata: info.showMetadata,
                password: password,
                provider: provider.providerType
            )

            // Check for duplicates
            if albums.contains(where: { $0.id == display.id }) {
                errorMessage = "This album is already added."
                return
            }

            // Save to local first (instant)
            localService.addAlbum(display)
            albums.insert(display, at: 0)

            // Index in Spotlight
            spotlightService.indexAlbum(display)

            // Update widget data
            updateWidgetData(albums)

            // Then save to CloudKit (background) if enabled
            if iCloudSyncEnabled {
                Task {
                    do {
                        try await cloudKitService.save(display)
                    } catch {
                        print("Failed to save to CloudKit: \(error.localizedDescription)")
                        // Local save succeeded, so don't show error to user
                        // CloudKit will sync on next launch
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAlbum(_ album: DisplayAlbum) async {
        // Remove from local first (instant)
        localService.deleteAlbum(id: album.id)
        albums.removeAll { $0.id == album.id }

        // Remove from Spotlight
        spotlightService.deindexAlbum(albumId: album.albumId)

        // Update widget data
        updateWidgetData(albums)

        // Then remove from CloudKit (background) if enabled
        if iCloudSyncEnabled {
            Task {
                do {
                    try await cloudKitService.delete(albumId: album.id)
                } catch {
                    print("Failed to delete from CloudKit: \(error.localizedDescription)")
                    // Local delete succeeded, CloudKit will sync on next launch
                }
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    /// Update shared widget data and reload timelines
    private func updateWidgetData(_ albums: [DisplayAlbum]) {
        SharedAlbumData.saveAlbums(albums)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
