//
//  LazyLoadingImage.swift
//  OmniAlbum
//
//  Image loading using Kingfisher for efficient caching and loading.
//

import SwiftUI
import Kingfisher

// MARK: - Cached async image view (uses Kingfisher)

struct CachedAsyncImage: View {
    let url: URL?
    /// Longest side, in pixels, the image is decoded at. Tiles are ~400 px; decoding thumbnails at full size
    /// piles up memory in long albums.
    var maxPixel: CGFloat = 512
    /// Extra request headers (an account's bearer token), applied to this view's loads only.
    var headers: [String: String]? = nil
    /// Namespaces the cache entry (e.g. per account), so two users on one server never share a cached image.
    var cacheScope: String? = nil

    var body: some View {
        ZStack {
            // Placeholder background
            Color(.systemGray5)

            if let url = url {
                KFImage(source: .network(ImageLoading.resource(for: url, scope: cacheScope)))
                    .requestModifier(ImageLoading.modifier(headers: headers))
                    .setProcessor(DownsamplingImageProcessor(size: CGSize(width: maxPixel, height: maxPixel)))
                    .scaleFactor(1) // size above is already pixels
                    .cacheOriginalImage()
                    .placeholder {
                        Color(.systemGray5)
                    }
                    .fade(duration: 0.15)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .clipped()
    }
}

/// Kingfisher resource and options for loads that may need a bearer token and a per-account cache scope.
enum ImageLoading {
    static func resource(for url: URL, scope: String?) -> Kingfisher.Resource {
        guard let scope else { return KF.ImageResource(downloadURL: url) }
        return KF.ImageResource(downloadURL: url, cacheKey: "\(scope)|\(url.absoluteString)")
    }

    static func modifier(headers: [String: String]?) -> AnyModifier {
        AnyModifier { request in
            guard let headers else { return request }
            var r = request
            headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            return r
        }
    }
}

// MARK: - Lazy loading image (asset grid)

struct LazyLoadingImage: View {
    let url: URL?
    let aspectRatio: CGFloat
    let cornerRadius: CGFloat

    init(url: URL?, aspectRatio: CGFloat = 1, cornerRadius: CGFloat = 4) {
        self.url = url
        self.aspectRatio = aspectRatio
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        CachedAsyncImage(url: url)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .aspectRatio(aspectRatio, contentMode: .fill)
            .clipped()
            .contentShape(Rectangle())
            .clipShape(.rect(cornerRadius: cornerRadius))
    }
}

// MARK: - Kingfisher Configuration

enum ImageCacheConfig {
    // Cache limits
    static let memoryCacheLimit: UInt = 150 * 1024 * 1024 // 150 MB
    static let memoryCacheCountLimit = 200
    static let diskCacheLimit: UInt = 1024 * 1024 * 1024 // 1 GB for local caching
    static let cacheExpirationDays = 30

    static func configure() {
        // Configure memory cache
        ImageCache.default.memoryStorage.config.totalCostLimit = Int(memoryCacheLimit)
        ImageCache.default.memoryStorage.config.countLimit = memoryCacheCountLimit

        // Configure disk cache - larger for local caching
        ImageCache.default.diskStorage.config.sizeLimit = diskCacheLimit
        ImageCache.default.diskStorage.config.expiration = .days(cacheExpirationDays)
    }
}
