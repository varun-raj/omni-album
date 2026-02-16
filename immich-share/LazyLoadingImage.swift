//
//  LazyLoadingImage.swift
//  immich-share
//
//  Image loading using Kingfisher for efficient caching and loading.
//

import SwiftUI
import Kingfisher

// MARK: - Cached async image view (uses Kingfisher)

struct CachedAsyncImage: View {
    let url: URL?

    var body: some View {
        ZStack {
            // Placeholder background
            Color(.systemGray5)

            if let url = url {
                KFImage(url)
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
