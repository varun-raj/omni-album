//
//  ScatterPhotoGrid.swift
//  OmniAlbum
//
//  Album asset grid backed by ScatterCore (justified rows, spring open/scatter, pager).
//  ScatterCore calls `content` on its own background queue and wants a CGImage back, so
//  ScatterTileLoader blocks that queue on Kingfisher (or the provider's decryptor).
//

import SwiftUI
import ImageIO
import ScatterCore
import Kingfisher

struct ScatterPhotoGrid: View {
    @ObservedObject var viewModel: AlbumDetailViewModel
    let controller: ScatterGridController
    let onVideo: (Asset) -> Void
    /// Swipe-up on an open tile passes its asset; swipe-down / tap while info is shown passes nil.
    let onInfo: (Asset?) -> Void
    let onShare: (Asset) -> Void
    let onSave: (Asset) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var assetsByID: [String: Asset] {
        Dictionary(viewModel.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var items: [ScatterItem] {
        viewModel.assets.map { asset in
            let size = pixelSize(of: asset)
            let isVideo = asset.type == .video
            return ScatterItem(
                id: asset.id,
                aspect: size.map { $0.width / $0.height } ?? 1,
                title: asset.originalFileName,
                // `external` tiles call onActivate instead of staging: videos need AVPlayer, not a still.
                subtitle: isVideo ? Self.durationText(asset.duration) : "",
                external: isVideo,
                pixelSize: size ?? .zero
            )
        }
    }

    private var config: ScatterConfig {
        var c = ScatterConfig()
        c.rowHeight = 110
        c.gap = 2
        c.cornerRadius = 2
        // Resolve for the current appearance; colorScheme is read above so a change re-runs body.
        c.background = UIColor.systemBackground
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)).cgColor
        return c
    }

    var body: some View {
        let lookup = assetsByID
        ScatterGrid(
            items: items,
            config: config,
            content: viewModel.tileContent(),
            onActivate: { id in if let asset = lookup[id] { onVideo(asset) } },
            onInfo: viewModel.showMetadata ? { id in onInfo(id.flatMap { lookup[$0] }) } : nil,
            tileIcon: { id in lookup[id]?.type == .video ? Self.playGlyph : nil },
            tileMenu: { item in
                guard viewModel.allowDownload, let asset = lookup[item.id], asset.type == .image else { return nil }
                return UIMenu(children: [
                    UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in onShare(asset) },
                    UIAction(title: "Save to Photos", image: UIImage(systemName: "square.and.arrow.down")) { _ in onSave(asset) },
                ])
            },
            controller: controller
        )
        .ignoresSafeArea(edges: .bottom)
    }

    private func pixelSize(of asset: Asset) -> CGSize? {
        let w = asset.width ?? asset.exif?.width, h = asset.height ?? asset.exif?.height
        guard let w, let h, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// "H:MM:SS" from the providers -> "M:SS".
    private static func durationText(_ duration: String?) -> String {
        guard let duration, duration != "0:00:00" else { return "" }
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return String(format: "%d:%02d", parts[0] * 60 + parts[1], parts[2])
        case 2: return String(format: "%d:%02d", parts[0], parts[1])
        default: return duration
        }
    }

    private static let playGlyph: CGImage? = {
        let glyph = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        return glyph.flatMap { g in
            UIGraphicsImageRenderer(size: g.size).image { _ in g.withTintColor(.white).draw(at: .zero) }.cgImage
        }
    }()
}

// MARK: - Tile loading

enum ScatterTileLoader {
    private final class Box<T>: @unchecked Sendable { var value: T? }

    /// Snapshot of what a tile needs, so the returned closure is safe to run off the main actor.
    static func content(provider: any ShareLinkProvider, album: DisplayAlbum, assets: [Asset]) -> TileContentProvider {
        let byID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return { id, maxPixel, full in
            guard let asset = byID[id] else { return nil }
            if provider.requiresClientDecryption {
                return decrypted(provider: provider, album: album, asset: asset, maxPixel: maxPixel, full: full)
            }
            let url = full
                ? provider.previewURL(baseURL: album.baseURL, asset: asset, shareKey: album.shareKey)
                : provider.thumbnailURL(baseURL: album.baseURL, assetId: asset.id, shareKey: album.shareKey)
            return url.flatMap { fetch($0, maxPixel: maxPixel) }
        }
    }

    // ScatterCore's decode queue is a plain OperationQueue (4 wide), so blocking here is expected.
    private static func fetch(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        let done = DispatchSemaphore(value: 0), box = Box<CGImage>()
        KingfisherManager.shared.retrieveImage(
            with: url,
            options: [
                .processor(DownsamplingImageProcessor(size: CGSize(width: maxPixel, height: maxPixel))),
                .scaleFactor(1), // size above is already pixels
                .cacheOriginalImage,
                .callbackQueue(.dispatch(.global(qos: .userInitiated))),
            ]
        ) { result in
            box.value = try? result.get().image.cgImage
            done.signal()
        }
        _ = done.wait(timeout: .now() + 60)
        return box.value
    }

    private static func decrypted(provider: any ShareLinkProvider, album: DisplayAlbum, asset: Asset, maxPixel: CGFloat, full: Bool) -> CGImage? {
        let done = DispatchSemaphore(value: 0), box = Box<Data>()
        Task.detached {
            box.value = try? await provider.fetchDecryptedData(
                baseURL: album.baseURL, asset: asset, shareKey: album.shareKey, variant: full ? .preview : .thumbnail)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 60)
        guard let data = box.value, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }
}
