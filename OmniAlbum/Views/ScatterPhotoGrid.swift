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
import Kingfisher

struct ScatterPhotoGrid: View {
    @ObservedObject var viewModel: AlbumDetailViewModel
    let controller: ScatterGridController
    let onVideo: (Asset) -> Void
    /// Id of the tile that opened, nil when it closes.
    let onOpen: (String?) -> Void
    /// Swipe-up on an open tile passes its asset; swipe-down / tap while info is shown passes nil.
    let onInfo: (Asset?) -> Void
    let onShare: (Asset) -> Void
    let onSave: (Asset) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var assetsByID: [String: Asset] {
        Dictionary(viewModel.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var items: [ScatterItem] {
        viewModel.assets.map { asset in
            let size = pixelSize(of: asset)
            let isVideo = asset.type == .video
            return ScatterItem(
                id: asset.id,
                aspect: size.map { $0.width / $0.height } ?? 1, // opened tile keeps the real shape; the grid is squares (config.columns)
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
        c.columns = horizontalSizeClass == .regular ? 6 : 3
        c.gap = 2
        c.edgeInset = 0 // edge to edge
        c.openBackground = CGColor(gray: 0, alpha: 1) // dark stage for viewing
        c.stageMargin = 0 // opened photo fills the viewport
        // Critically damped and a touch slower than the defaults: no overshoot, steadier pace.
        c.item = .bounce(0, response: 0.4)
        c.openDuration = 0.4; c.closeDuration = 0.4; c.scatterDuration = 0.45; c.cornerDuration = 0.4
        c.cornerRadius = 0
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
            onOpen: onOpen,
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

// MARK: - Bar fading

/// Fades the navigation and tab bars by alpha. `.toolbar(.hidden)` re-lays out the screen, which makes the
/// opening photo jump; alpha leaves every frame (and so ScatterCore's animation targets) untouched.
struct BarsFader: UIViewControllerRepresentable {
    let hidden: Bool

    final class Coordinator {
        weak var nav: UINavigationController?
        weak var tab: UITabBar?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    /// Never leave the bars invisible after leaving the screen (e.g. swipe-back while a photo is open).
    static func dismantleUIViewController(_ vc: UIViewController, coordinator: Coordinator) {
        coordinator.nav?.navigationBar.alpha = 1
        coordinator.tab?.alpha = 1
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        let alpha: CGFloat = hidden ? 0 : 1
        // The representable's controller may not be attached yet on first pass.
        DispatchQueue.main.async {
            let nav = vc.navigationController
            let tab = vc.tabBarController?.tabBar
            context.coordinator.nav = nav
            context.coordinator.tab = tab
            guard nav?.navigationBar.alpha != alpha || tab?.alpha != alpha else { return }
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                nav?.navigationBar.alpha = alpha
                tab?.alpha = alpha
            }
        }
    }
}
