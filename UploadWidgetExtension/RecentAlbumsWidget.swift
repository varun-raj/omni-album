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
}

enum WidgetAlbumData {
    static let appGroupId = "group.com.skcript.immich-share"
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
        var comp = URLComponents(string: entry.baseURL)
        comp?.path = "/api/assets/\(assetId)/thumbnail"
        comp?.queryItems = [URLQueryItem(name: "key", value: entry.shareKey)]
        return comp?.url
    }
}

// MARK: - Timeline Entry

struct AlbumWidgetEntry: TimelineEntry {
    let date: Date
    let albums: [WidgetAlbumEntry]
}

// MARK: - Timeline Provider

struct AlbumWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AlbumWidgetEntry {
        AlbumWidgetEntry(date: .now, albums: [
            WidgetAlbumEntry(albumId: "1", albumName: "Vacation Photos", baseURL: "", shareKey: "", thumbnailAssetId: nil, assetCount: 42),
            WidgetAlbumEntry(albumId: "2", albumName: "Family", baseURL: "", shareKey: "", thumbnailAssetId: nil, assetCount: 128),
            WidgetAlbumEntry(albumId: "3", albumName: "Travel", baseURL: "", shareKey: "", thumbnailAssetId: nil, assetCount: 56),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (AlbumWidgetEntry) -> Void) {
        let albums = WidgetAlbumData.loadAlbums()
        completion(AlbumWidgetEntry(date: .now, albums: albums))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AlbumWidgetEntry>) -> Void) {
        let albums = WidgetAlbumData.loadAlbums()
        let entry = AlbumWidgetEntry(date: .now, albums: albums)
        // Refresh every 30 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: .now)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget Views

struct RecentAlbumsWidget: Widget {
    let kind = "RecentAlbumsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AlbumWidgetProvider()) { entry in
            AlbumWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recent Albums")
        .description("Quick access to your Immich shared albums.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

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
                    WidgetThumbnailView(url: WidgetAlbumData.thumbnailURL(for: album))
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
                            WidgetThumbnailView(url: WidgetAlbumData.thumbnailURL(for: album))
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
                                WidgetThumbnailView(url: WidgetAlbumData.thumbnailURL(for: album))
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
    let url: URL?

    var body: some View {
        if let url = url {
            // In widgets, we use AsyncImage since Kingfisher isn't available
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    placeholderView
                case .empty:
                    placeholderView
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                @unknown default:
                    placeholderView
                }
            }
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        Rectangle()
            .fill(Color(.systemGray5))
            .overlay {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
    }
}
