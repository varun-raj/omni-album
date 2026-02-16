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
    @Published private(set) var assets: [ImmichAsset] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var albumDetails: AlbumWithAssetsResponse?
    @Published private(set) var dateRangeText: String?

    private let shareService = ImmichShareService()
    let album: DisplayAlbum

    /// Shared instance cache for refreshing after upload
    private static var instances: [String: WeakRef<AlbumDetailViewModel>] = [:]

    init(album: DisplayAlbum) {
        self.album = album
        // Register this instance for later refresh
        Self.instances[album.albumId] = WeakRef(self)
    }

    /// Get the active view model for an album (if any)
    static func instance(for albumId: String) -> AlbumDetailViewModel? {
        return instances[albumId]?.value
    }

    /// Computes date range text from assets (e.g., "Jan 2024" or "Jan - Mar 2024")
    /// Called once after assets are loaded, off main thread
    nonisolated private func computeDateRangeText(from assets: [ImmichAsset]) -> String? {
        guard !assets.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        let dates = assets.compactMap { asset -> Date? in
            let dateString = asset.fileCreatedAt ?? asset.localDateTime ?? asset.createdAt ?? ""
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
        albumDetails?.owner.name
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
        var comp = URLComponents(string: album.baseURL)
        comp?.path = "/api/assets/\(thumbnailId)/thumbnail"
        comp?.queryItems = [
            URLQueryItem(name: "key", value: album.shareKey),
            URLQueryItem(name: "size", value: "preview")
        ]
        return comp?.url
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
            let response = try await shareService.fetchAlbumWithAssets(
                baseURL: album.baseURL,
                albumId: album.albumId,
                shareKey: album.shareKey,
                password: album.password
            )
            albumDetails = response
            assets = response.assets
            errorMessage = nil

            // Notify album list to update its data
            NotificationCenter.default.post(
                name: .albumDataUpdated,
                object: nil,
                userInfo: [
                    "albumId": album.albumId,
                    "assetCount": response.assetCount,
                    "thumbnailId": response.albumThumbnailAssetId as Any
                ]
            )

            // Compute date range off main thread after UI updates
            let loadedAssets = response.assets
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

    func thumbnailURL(for asset: ImmichAsset) -> URL? {
        AggregatorViewModel.thumbnailURL(
            baseURL: album.baseURL,
            assetId: asset.id,
            shareKey: album.shareKey
        )
    }

    /// High-res preview URL for lightbox: same path as thumbnail with size=preview and edited=true.
    func previewURL(for asset: ImmichAsset) -> URL? {
        var comp = URLComponents(string: album.baseURL)
        comp?.path = "/api/assets/\(asset.id)/thumbnail"
        comp?.queryItems = [
            URLQueryItem(name: "key", value: album.shareKey),
            URLQueryItem(name: "size", value: "preview"),
            URLQueryItem(name: "edited", value: "true")
        ]
        return comp?.url
    }

    /// Original full-resolution asset URL for downloading the original file
    func originalURL(for asset: ImmichAsset) -> URL? {
        var comp = URLComponents(string: album.baseURL)
        comp?.path = "/api/assets/\(asset.id)/original"
        comp?.queryItems = [
            URLQueryItem(name: "key", value: album.shareKey)
        ]
        return comp?.url
    }

    /// Preview/full asset URL (Immich viewAsset). Use thumbnailURL for reliability.
    func assetURL(for asset: ImmichAsset, size: String = "preview") -> URL? {
        var comp = URLComponents(string: album.baseURL)
        comp?.path = "/api/assets/\(asset.id)"
        comp?.queryItems = [
            URLQueryItem(name: "key", value: album.shareKey),
            URLQueryItem(name: "size", value: size)
        ]
        return comp?.url
    }

    /// Video playback URL for streaming videos
    func videoPlaybackURL(for asset: ImmichAsset) -> URL? {
        guard asset.type.lowercased() == "video" else { return nil }
        var comp = URLComponents(string: album.baseURL)
        comp?.path = "/api/assets/\(asset.id)/video/playback"
        var queryItems = [URLQueryItem(name: "key", value: album.shareKey)]
        if let checksum = asset.checksum {
            queryItems.append(URLQueryItem(name: "c", value: checksum))
        }
        comp?.queryItems = queryItems
        return comp?.url
    }

    /// Check if asset is a video
    func isVideo(_ asset: ImmichAsset) -> Bool {
        asset.type.lowercased() == "video"
    }
}

// MARK: - Weak Reference Wrapper

private class WeakRef<T: AnyObject> {
    weak var value: T?
    init(_ value: T) {
        self.value = value
    }
}

