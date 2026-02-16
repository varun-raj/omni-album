//
//  AlbumDetailViewModel.swift
//  immich-share
//
//  Loads and holds assets for a single album (lazy load on appear).
//

import Foundation
import Combine

@MainActor
final class AlbumDetailViewModel: ObservableObject {
    @Published private(set) var assets: [Asset] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var albumDetails: AlbumDetail?
    @Published private(set) var dateRangeText: String?

    private let provider: any ShareLinkProvider
    let album: DisplayAlbum

    /// Shared instance cache for refreshing after upload
    private static var instances: [String: WeakRef<AlbumDetailViewModel>] = [:]

    init(album: DisplayAlbum) {
        self.album = album
        self.provider = ProviderRegistry.shared.provider(for: album.provider)
            ?? ProviderRegistry.shared.provider(for: .immich)!
        // Register this instance for later refresh
        Self.instances[album.albumId] = WeakRef(self)
    }

    /// Get the active view model for an album (if any)
    static func instance(for albumId: String) -> AlbumDetailViewModel? {
        return instances[albumId]?.value
    }

    /// Computes date range text from assets (e.g., "Jan 2024" or "Jan - Mar 2024")
    /// Called once after assets are loaded, off main thread
    nonisolated private func computeDateRangeText(from assets: [Asset]) -> String? {
        guard !assets.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        let dates = assets.compactMap { asset -> Date? in
            let dateString = asset.createdAt ?? ""
            guard !dateString.isEmpty else { return nil }
            return isoFormatter.date(from: dateString)
                ?? fallbackFormatter.date(from: dateString)
        }

        guard let minDate = dates.min(), let maxDate = dates.max() else { return nil }

        let calendar = Calendar.current
        let minComponents = calendar.dateComponents([.month, .year], from: minDate)
        let maxComponents = calendar.dateComponents([.month, .year], from: maxDate)

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM"

        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "yyyy"

        let minMonth = monthFormatter.string(from: minDate)
        let minYear = yearFormatter.string(from: minDate)
        let maxMonth = monthFormatter.string(from: maxDate)
        let maxYear = yearFormatter.string(from: maxDate)

        if minComponents.year == maxComponents.year {
            if minComponents.month == maxComponents.month {
                return "\(minMonth) \(minYear)"
            } else {
                return "\(minMonth) - \(maxMonth) \(maxYear)"
            }
        } else {
            return "\(minMonth) \(minYear) - \(maxMonth) \(maxYear)"
        }
    }

    /// The share link URL for this album
    var shareURL: String {
        "\(album.baseURL)/share/\(album.shareKey)"
    }

    /// Owner name from the album details
    var ownerName: String? {
        albumDetails?.ownerName
    }

    /// Album description from the album details
    var albumDescription: String? {
        guard let desc = albumDetails?.description, !desc.isEmpty else { return nil }
        return desc
    }

    /// Whether uploads are allowed for this album
    var allowUpload: Bool {
        album.allowUpload
    }

    /// Whether downloads are allowed for this album
    var allowDownload: Bool {
        album.allowDownload
    }

    /// Whether metadata should be shown for this album
    var showMetadata: Bool {
        album.showMetadata
    }

    /// High-quality cover image URL for the album header
    var coverImageURL: URL? {
        guard let thumbnailId = album.albumThumbnailAssetId, !thumbnailId.isEmpty else { return nil }
        // Use a dummy asset to get a preview-sized URL, or build directly via thumbnail
        // For the cover, we use the thumbnail endpoint with preview size
        return provider.thumbnailURL(baseURL: album.baseURL, assetId: thumbnailId, shareKey: album.shareKey)
    }

    /// Cover image URL at preview quality (higher res than thumbnail)
    var coverPreviewURL: URL? {
        guard let thumbnailId = album.albumThumbnailAssetId, !thumbnailId.isEmpty else { return nil }
        let dummyAsset = Asset(
            id: thumbnailId, type: .image, originalFileName: "",
            createdAt: nil, duration: nil, thumbhash: nil,
            width: nil, height: nil, exif: nil, providerData: nil
        )
        return provider.previewURL(baseURL: album.baseURL, asset: dummyAsset, shareKey: album.shareKey)
    }

    func loadIfNeeded() async {
        if assets.isEmpty && !isLoading {
            // Initial load
            isLoading = true
            errorMessage = nil
            await fetchAlbumData()
            isLoading = false
        } else if !assets.isEmpty && !isRefreshing {
            // Background refresh for fresh data
            isRefreshing = true
            await fetchAlbumData()
            isRefreshing = false
        }
    }

    /// Force refresh album data
    func refresh() async {
        guard !isLoading && !isRefreshing else { return }
        isRefreshing = true
        await fetchAlbumData()
        isRefreshing = false
    }

    private func fetchAlbumData() async {
        do {
            let detail = try await provider.fetchAlbumDetail(
                baseURL: album.baseURL,
                albumId: album.albumId,
                shareKey: album.shareKey,
                password: album.password
            )
            albumDetails = detail
            assets = detail.assets
            errorMessage = nil

            // Notify album list to update its data
            NotificationCenter.default.post(
                name: .albumDataUpdated,
                object: nil,
                userInfo: [
                    "albumId": album.albumId,
                    "assetCount": detail.assetCount,
                    "thumbnailId": detail.thumbnailAssetId as Any
                ]
            )

            // Compute date range off main thread after UI updates
            let loadedAssets = detail.assets
            let computedDateRange = await Task.detached { [weak self] in
                self?.computeDateRangeText(from: loadedAssets)
            }.value
            dateRangeText = computedDateRange
        } catch {
            // Only show error if we have no data
            if assets.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    func thumbnailURL(for asset: Asset) -> URL? {
        provider.thumbnailURL(baseURL: album.baseURL, assetId: asset.id, shareKey: album.shareKey)
    }

    /// High-res preview URL for lightbox
    func previewURL(for asset: Asset) -> URL? {
        provider.previewURL(baseURL: album.baseURL, asset: asset, shareKey: album.shareKey)
    }

    /// Original full-resolution asset URL for downloading
    func originalURL(for asset: Asset) -> URL? {
        provider.originalURL(baseURL: album.baseURL, asset: asset, shareKey: album.shareKey)
    }

    /// Video playback URL for streaming videos
    func videoPlaybackURL(for asset: Asset) -> URL? {
        provider.videoPlaybackURL(baseURL: album.baseURL, asset: asset, shareKey: album.shareKey)
    }

    /// Check if asset is a video
    func isVideo(_ asset: Asset) -> Bool {
        asset.type == .video
    }
}

// MARK: - Weak Reference Wrapper

private class WeakRef<T: AnyObject> {
    weak var value: T?
    init(_ value: T) {
        self.value = value
    }
}
