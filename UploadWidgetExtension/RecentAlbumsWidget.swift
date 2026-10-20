//
//  RecentAlbumsWidget.swift
//  UploadWidgetExtension
//
//  Home screen widget showing recent albums.
//

import SwiftUI
import WidgetKit

// MARK: - Shared Data (duplicated from main app for widget target)

struct WidgetAlbumEntry: Codable {
    let albumId: String
    let albumName: String
    let baseURL: String
    let shareKey: String
    let thumbnailAssetId: String?
    let assetCount: Int?
    let provider: String?
}

enum WidgetAlbumData {
    static let appGroupId = "group.com.skcript.omnialbum"
    private static let albumsKey = "widgetAlbums"

    static func loadAlbums() -> [WidgetAlbumEntry] {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: albumsKey),
              let entries = try? JSONDecoder().decode([WidgetAlbumEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func thumbnailURL(for entry: WidgetAlbumEntry) -> URL? {
        guard let assetId = entry.thumbnailAssetId, !assetId.isEmpty else { return nil }
        let provider = entry.provider ?? "immich"

        switch provider {
        case "immich":
            var comp = URLComponents(string: entry.baseURL)
            comp?.path = "/api/assets/\(assetId)/thumbnail"
            comp?.queryItems = [URLQueryItem(name: "key", value: entry.shareKey)]
            return comp?.url
        case "nextcloud":
            var comp = URLComponents(string: entry.baseURL)
            comp?.path = "/index.php/apps/files_sharing/publicpreview/\(entry.shareKey)"
            comp?.queryItems = [
                URLQueryItem(name: "file", value: assetId),
                URLQueryItem(name: "x", value: "512"),
                URLQueryItem(name: "y", value: "512"),
                URLQueryItem(name: "a", value: "1")
            ]
            return comp?.url
        case "photoprism":
            var comp = URLComponents(string: entry.baseURL)
            comp?.path = "/api/v1/t/\(assetId)/public/tile_224"
            return comp?.url
        case "ente":
            // Ente thumbnails are cached locally as file:// URLs
            return URL(string: assetId)
        default:
            return nil
        }
    }
}

// MARK: - Timeline Entry

struct AlbumDisplayItem {
    let albumName: String
    let assetCount: Int?
    let thumbnail: UIImage?
}

struct AlbumWidgetEntry: TimelineEntry {
    let date: Date
    let albums: [AlbumDisplayItem]
}

// MARK: - Timeline Provider

struct AlbumWidgetProvider: TimelineProvider {
    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func placeholder(in context: Context) -> AlbumWidgetEntry {
        AlbumWidgetEntry(date: .now, albums: [
            AlbumDisplayItem(albumName: "Vacation Photos", assetCount: 42, thumbnail: nil),
            AlbumDisplayItem(albumName: "Family", assetCount: 128, thumbnail: nil),
            AlbumDisplayItem(albumName: "Travel", assetCount: 56, thumbnail: nil),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (AlbumWidgetEntry) -> Void) {
        let albums = WidgetAlbumData.loadAlbums()
        if context.isPreview {
            let items = albums.map { AlbumDisplayItem(albumName: $0.albumName, assetCount: $0.assetCount, thumbnail: nil) }
            completion(AlbumWidgetEntry(date: .now, albums: items))
            return
        }
        downloadThumbnails(for: albums, completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AlbumWidgetEntry>) -> Void) {
        let albums = WidgetAlbumData.loadAlbums()
        downloadThumbnails(for: albums) { entry in
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: .now)!
            let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
            completion(timeline)
        }
    }

    private func downloadThumbnails(for albums: [WidgetAlbumEntry], completion: @escaping (AlbumWidgetEntry) -> Void) {
        let group = DispatchGroup()
        let maxAlbums = min(albums.count, 6)
        var results: [(Int, AlbumDisplayItem)] = []
        let lock = NSLock()

        for i in 0..<maxAlbums {
            let album = albums[i]
            guard let url = WidgetAlbumData.thumbnailURL(for: album) else {
                lock.lock()
                results.append((i, AlbumDisplayItem(albumName: album.albumName, assetCount: album.assetCount, thumbnail: nil)))
                lock.unlock()
                continue
            }

            // file:// URLs (e.g. Ente cached thumbnails) — load from disk
            if url.isFileURL {
                let image = UIImage(contentsOfFile: url.path)
                lock.lock()
                results.append((i, AlbumDisplayItem(albumName: album.albumName, assetCount: album.assetCount, thumbnail: image)))
                lock.unlock()
                continue
            }

            group.enter()
            Self.urlSession.dataTask(with: url) { data, _, _ in
                let image = data.flatMap { UIImage(data: $0) }
                lock.lock()
                results.append((i, AlbumDisplayItem(albumName: album.albumName, assetCount: album.assetCount, thumbnail: image)))
                lock.unlock()
                group.leave()
            }.resume()
        }

        group.notify(queue: .main) {
            let sorted = results.sorted { $0.0 < $1.0 }.map(\.1)
            completion(AlbumWidgetEntry(date: .now, albums: sorted))
        }
    }
}

// MARK: - Widget

struct RecentAlbumsWidget: Widget {
    let kind = "RecentAlbumsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AlbumWidgetProvider()) { entry in
            AlbumWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recent Albums")
        .description("Quick access to your shared albums.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Widget Views

struct AlbumWidgetEntryView: View {
    let entry: AlbumWidgetEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .systemMedium:
            mediumWidget
        case .systemLarge:
            largeWidget
        default:
            smallWidget
        }
    }

    // MARK: - Small Widget (1 album)

    private var smallWidget: some View {
        Group {
            if let album = entry.albums.first {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetThumbnailView(image: album.thumbnail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(.rect(cornerRadius: 8))

                    Text(album.albumName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)

                    if let count = album.assetCount {
                        Text(photoCountText(count))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                emptyView
            }
        }
    }

    // MARK: - Medium Widget (2-3 albums)

    private var mediumWidget: some View {
        Group {
            if entry.albums.isEmpty {
                emptyView
            } else {
                HStack(spacing: 10) {
                    ForEach(Array(entry.albums.prefix(3).enumerated()), id: \.offset) { _, album in
                        VStack(alignment: .leading, spacing: 4) {
                            WidgetThumbnailView(image: album.thumbnail)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 8))

                            Text(album.albumName)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)

                            if let count = album.assetCount {
                                Text(photoCountText(count))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Large Widget (4-6 albums)

    private var largeWidget: some View {
        Group {
            if entry.albums.isEmpty {
                emptyView
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Albums")
                        .font(.headline)

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ], spacing: 10) {
                        ForEach(Array(entry.albums.prefix(6).enumerated()), id: \.offset) { _, album in
                            VStack(alignment: .leading, spacing: 4) {
                                WidgetThumbnailView(image: album.thumbnail)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(.rect(cornerRadius: 8))

                                Text(album.albumName)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)

                                if let count = album.assetCount {
                                    Text(photoCountText(count))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No Albums")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func photoCountText(_ count: Int) -> String {
        count == 1 ? "1 Photo" : "\(count) Photos"
    }
}

// MARK: - Widget Thumbnail

private struct WidgetThumbnailView: View {
    let image: UIImage?

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color(.systemGray5))
                .overlay {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
        }
    }
}
