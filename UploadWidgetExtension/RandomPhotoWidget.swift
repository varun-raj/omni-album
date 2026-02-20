//
//  RandomPhotoWidget.swift
//  UploadWidgetExtension
//
//  "On This Day" widget showing a photo from the user's albums,
//  preferring photos taken on today's date in previous years.
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Shared Data Types (duplicated for widget isolation)

/// Cached pool of image asset IDs for a single album
private struct WidgetAssetPool: Codable {
    let albumId: String
    let provider: String
    let baseURL: String
    let shareKey: String
    let albumName: String
    let assetIds: [String]
    let assetDates: [String]?  // Parallel array of ISO8601 date strings
    let lastUpdated: Date
}

private enum WidgetAssetPoolData {
    static let appGroupId = "group.com.skcript.omnialbum"
    private static let assetPoolsKey = "widgetAssetPools"

    static func loadPools() -> [WidgetAssetPool] {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: assetPoolsKey),
              let pools = try? JSONDecoder().decode([WidgetAssetPool].self, from: data) else {
            return []
        }
        return pools
    }

    static func savePools(_ pools: [WidgetAssetPool]) {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = try? JSONEncoder().encode(pools) else { return }
        defaults.set(data, forKey: assetPoolsKey)
    }
}

// MARK: - App Intent for Album Selection

struct AlbumEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Album")
    static var defaultQuery = AlbumEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct AlbumEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        let albums = WidgetAlbumData.loadAlbums()
        return identifiers.compactMap { id in
            if let album = albums.first(where: { $0.albumId == id }) {
                return AlbumEntity(id: album.albumId, name: album.albumName)
            }
            return nil
        }
    }

    func suggestedEntities() async throws -> [AlbumEntity] {
        WidgetAlbumData.loadAlbums().map { AlbumEntity(id: $0.albumId, name: $0.albumName) }
    }
}

struct RandomPhotoIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "On This Day"
    static var description = IntentDescription("Shows a photo from this day in previous years.")

    @Parameter(title: "Album")
    var album: AlbumEntity?
}

// MARK: - Timeline Entry

struct RandomPhotoEntry: TimelineEntry {
    let date: Date
    let albumId: String?
    let albumName: String?
    let assetId: String?
    let photo: UIImage?
    let photoYear: Int?
    let isEmpty: Bool

    var deepLinkURL: URL? {
        guard let albumId, let assetId else { return nil }
        var components = URLComponents()
        components.scheme = "omnialbum"
        components.host = "photo"
        components.queryItems = [
            URLQueryItem(name: "albumId", value: albumId),
            URLQueryItem(name: "assetId", value: assetId)
        ]
        return components.url
    }
}

// MARK: - Timeline Provider

struct RandomPhotoProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> RandomPhotoEntry {
        RandomPhotoEntry(date: .now, albumId: nil, albumName: "My Album", assetId: nil, photo: nil, photoYear: 2021, isEmpty: false)
    }

    func snapshot(for configuration: RandomPhotoIntent, in context: Context) async -> RandomPhotoEntry {
        if context.isPreview {
            return RandomPhotoEntry(date: .now, albumId: nil, albumName: "My Album", assetId: nil, photo: nil, photoYear: 2021, isEmpty: false)
        }
        return await loadRandomPhoto(for: configuration)
    }

    func timeline(for configuration: RandomPhotoIntent, in context: Context) async -> Timeline<RandomPhotoEntry> {
        let entry = await loadRandomPhoto(for: configuration)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func loadRandomPhoto(for configuration: RandomPhotoIntent) async -> RandomPhotoEntry {
        let albums = WidgetAlbumData.loadAlbums()
        guard !albums.isEmpty else {
            return RandomPhotoEntry(date: .now, albumId: nil, albumName: nil, assetId: nil, photo: nil, photoYear: nil, isEmpty: true)
        }

        let pools = WidgetAssetPoolData.loadPools()
        let calendar = Calendar.current
        let today = Date.now
        let todayMonth = calendar.component(.month, from: today)
        let todayDay = calendar.component(.day, from: today)

        // Try to find an "on this day" photo across all pools (or filtered by selected album)
        let filteredPools: [WidgetAssetPool]
        if let selectedId = configuration.album?.id {
            filteredPools = pools.filter { $0.albumId == selectedId }
        } else {
            filteredPools = pools
        }

        // Collect candidate (assetId, year, pool) tuples for photos taken on this day
        var onThisDayCandidates: [(assetId: String, year: Int, pool: WidgetAssetPool)] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for pool in filteredPools {
            guard let dates = pool.assetDates, dates.count == pool.assetIds.count else { continue }
            for (index, dateStr) in dates.enumerated() where !dateStr.isEmpty {
                if let assetDate = isoFormatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) {
                    let assetMonth = calendar.component(.month, from: assetDate)
                    let assetDay = calendar.component(.day, from: assetDate)
                    let assetYear = calendar.component(.year, from: assetDate)
                    if assetMonth == todayMonth && assetDay == todayDay && assetYear != calendar.component(.year, from: today) {
                        onThisDayCandidates.append((pool.assetIds[index], assetYear, pool))
                    }
                }
            }
        }

        // If we found "on this day" matches, pick one randomly
        if let candidate = onThisDayCandidates.randomElement() {
            let album = albums.first(where: { $0.albumId == candidate.pool.albumId }) ?? albums[0]
            let url = thumbnailURL(assetId: candidate.assetId, album: album)
            let image = await downloadImage(from: url)
            return RandomPhotoEntry(date: today, albumId: album.albumId, albumName: album.albumName, assetId: candidate.assetId, photo: image, photoYear: candidate.year, isEmpty: false)
        }

        // Fallback: pick a random photo (same logic as before)
        let album: WidgetAlbumEntry
        if let selectedId = configuration.album?.id,
           let found = albums.first(where: { $0.albumId == selectedId }) {
            album = found
        } else {
            album = albums.randomElement()!
        }

        let (assetId, year) = await pickRandomAsset(for: album, pools: pools)

        guard let assetId else {
            return RandomPhotoEntry(date: today, albumId: album.albumId, albumName: album.albumName, assetId: nil, photo: nil, photoYear: nil, isEmpty: false)
        }

        let url = thumbnailURL(assetId: assetId, album: album)
        let image = await downloadImage(from: url)
        return RandomPhotoEntry(date: today, albumId: album.albumId, albumName: album.albumName, assetId: assetId, photo: image, photoYear: year, isEmpty: false)
    }

    /// Picks a random image asset and its year.
    /// 1. Cached asset pool
    /// 2. Fetch from API (Immich) and cache for next time
    /// 3. Album thumbnail fallback
    private func pickRandomAsset(for album: WidgetAlbumEntry, pools: [WidgetAssetPool]) async -> (String?, Int?) {
        // 1. Try cached pool
        if let pool = pools.first(where: { $0.albumId == album.albumId }) {
            if let index = pool.assetIds.indices.randomElement() {
                let assetId = pool.assetIds[index]
                var year: Int?
                if let dates = pool.assetDates, index < dates.count, !dates[index].isEmpty {
                    let isoFormatter = ISO8601DateFormatter()
                    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let d = isoFormatter.date(from: dates[index]) ?? ISO8601DateFormatter().date(from: dates[index]) {
                        year = Calendar.current.component(.year, from: d)
                    }
                }
                return (assetId, year)
            }
        }

        // 2. Fetch from API and cache
        if let fetched = await fetchAndCacheAssets(for: album) {
            return fetched
        }

        // 3. Album thumbnail fallback
        if let thumbnailId = album.thumbnailAssetId, !thumbnailId.isEmpty {
            return (thumbnailId, nil)
        }

        return (nil, nil)
    }

    /// Fetch asset IDs from the provider API and cache them in the shared pool
    private func fetchAndCacheAssets(for album: WidgetAlbumEntry) async -> (String, Int?)? {
        let provider = album.provider ?? "immich"

        guard let assets = await fetchAssetsFromAPI(album: album, provider: provider) else {
            return nil
        }

        // Cache to shared pool for future use
        let assetIds = assets.map(\.id)
        let assetDates = assets.map(\.date)
        if !assetIds.isEmpty {
            var pools = WidgetAssetPoolData.loadPools()
            pools.removeAll { $0.albumId == album.albumId }
            let pool = WidgetAssetPool(
                albumId: album.albumId,
                provider: provider,
                baseURL: album.baseURL,
                shareKey: album.shareKey,
                albumName: album.albumName,
                assetIds: Array(assetIds.prefix(50)),
                assetDates: Array(assetDates.prefix(50)),
                lastUpdated: Date()
            )
            pools.append(pool)
            WidgetAssetPoolData.savePools(pools)
        }

        // Pick a random one
        guard let index = assets.indices.randomElement() else { return nil }
        let asset = assets[index]
        var year: Int?
        if !asset.date.isEmpty {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoFormatter.date(from: asset.date) ?? ISO8601DateFormatter().date(from: asset.date) {
                year = Calendar.current.component(.year, from: d)
            }
        }
        return (asset.id, year)
    }

    private struct FetchedAsset {
        let id: String
        let date: String
    }

    /// Provider-specific API call to fetch image asset IDs
    private func fetchAssetsFromAPI(album: WidgetAlbumEntry, provider: String) async -> [FetchedAsset]? {
        switch provider {
        case "immich":
            return await fetchImmichAssets(album: album)
        default:
            return nil
        }
    }

    /// Fetch assets from Immich API: GET /api/albums/{albumId}?key={shareKey}
    private func fetchImmichAssets(album: WidgetAlbumEntry) async -> [FetchedAsset]? {
        var comp = URLComponents(string: album.baseURL)
        comp?.path = "/api/albums/\(album.albumId)"
        comp?.queryItems = [URLQueryItem(name: "key", value: album.shareKey)]
        guard let url = comp?.url else { return nil }

        do {
            let (data, response) = try await Self.urlSession.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            // Lightweight JSON parsing - just extract asset IDs and dates
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]] else { return nil }

            return assets.compactMap { asset in
                guard let id = asset["id"] as? String,
                      let type = asset["type"] as? String,
                      type == "IMAGE" else { return nil }
                let createdAt = asset["fileCreatedAt"] as? String ?? asset["createdAt"] as? String ?? ""
                return FetchedAsset(id: id, date: createdAt)
            }
        } catch {
            return nil
        }
    }

    /// Build a thumbnail URL using provider-specific patterns
    private func thumbnailURL(assetId: String, album: WidgetAlbumEntry) -> URL? {
        let provider = album.provider ?? "immich"

        switch provider {
        case "immich":
            var comp = URLComponents(string: album.baseURL)
            comp?.path = "/api/assets/\(assetId)/thumbnail"
            comp?.queryItems = [URLQueryItem(name: "key", value: album.shareKey)]
            return comp?.url

        case "nextcloud":
            var comp = URLComponents(string: album.baseURL)
            comp?.path = "/index.php/apps/files_sharing/publicpreview/\(album.shareKey)"
            comp?.queryItems = [
                URLQueryItem(name: "file", value: assetId),
                URLQueryItem(name: "x", value: "1024"),
                URLQueryItem(name: "y", value: "1024"),
                URLQueryItem(name: "a", value: "1")
            ]
            return comp?.url

        case "photoprism":
            var comp = URLComponents(string: album.baseURL)
            comp?.path = "/api/v1/t/\(assetId)/public/tile_500"
            return comp?.url

        case "ente":
            return URL(string: assetId)

        default:
            return WidgetAlbumData.thumbnailURL(for: album)
        }
    }

    /// URLSession that trusts self-signed certificates (common for self-hosted servers)
    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: WidgetSessionDelegate.shared, delegateQueue: nil)
    }()

    /// Download image from URL
    private func downloadImage(from url: URL?) async -> UIImage? {
        guard let url else { return nil }

        if url.isFileURL {
            return UIImage(contentsOfFile: url.path)
        }

        do {
            let (data, _) = try await Self.urlSession.data(from: url)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}

/// Delegate that accepts self-signed certificates for self-hosted photo servers
final class WidgetSessionDelegate: NSObject, URLSessionDelegate {
    static let shared = WidgetSessionDelegate()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}

// MARK: - Widget

struct RandomPhotoWidget: Widget {
    let kind = "RandomPhotoWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: RandomPhotoIntent.self, provider: RandomPhotoProvider()) { entry in
            RandomPhotoWidgetView(entry: entry)
                .widgetURL(entry.deepLinkURL)
                .containerBackground(.white, for: .widget)
        }
        .configurationDisplayName("On This Day")
        .description("A photo from this day in previous years.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Widget View

struct RandomPhotoWidgetView: View {
    let entry: RandomPhotoEntry

    @Environment(\.widgetFamily) var family

    private var currentDay: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: entry.date)
    }

    private var currentMonth: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        return formatter.string(from: entry.date).uppercased()
    }

    /// Relative label like "3 YEARS AGO" or fallback "ON THIS DAY"
    private var headerLabel: String {
        guard let year = entry.photoYear else { return "ON THIS DAY" }
        let currentYear = Calendar.current.component(.year, from: entry.date)
        let diff = currentYear - year
        if diff == 1 { return "1 YEAR AGO" }
        if diff > 1 { return "\(diff) YEARS AGO" }
        return "ON THIS DAY"
    }

    var body: some View {
        if entry.isEmpty {
            emptyView
        } else if family == .systemMedium {
            mediumLayout
        } else {
            smallLayout
        }
    }

    // MARK: - Small Widget

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerLabel)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 0.95, green: 0.3, blue: 0.4))
                        .tracking(0.5)

                    Text(currentDay)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(currentMonth)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.gray)
                        .tracking(0.5)
                }

                Spacer()

                // Heart icon
                ZStack {
                    Circle()
                        .fill(Color(red: 0.95, green: 0.3, blue: 0.4).opacity(0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: "heart")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.95, green: 0.3, blue: 0.4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Photo
            photoArea
                .clipShape(.rect(cornerRadius: 10))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Medium Widget

    private var mediumLayout: some View {
        HStack(spacing: 0) {
            // Left side - date info
            VStack(alignment: .leading, spacing: 2) {
                Text(headerLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.95, green: 0.3, blue: 0.4))
                    .tracking(0.5)

                Text(currentDay)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.black)

                Text(currentMonth)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.gray)
                    .tracking(0.5)

                Spacer()

                // Heart icon
                ZStack {
                    Circle()
                        .fill(Color(red: 0.95, green: 0.3, blue: 0.4).opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: "heart")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(red: 0.95, green: 0.3, blue: 0.4))
                }
            }
            .padding(.leading, 14)
            .padding(.vertical, 10)
            .frame(maxHeight: .infinity)

            Spacer()

            // Right side - photo
            photoArea
                .clipShape(.rect(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
        }
    }

    // MARK: - Photo Area (shared)

    private var photoArea: some View {
        ZStack(alignment: .bottomLeading) {
            if let photo = entry.photo {
                GeometryReader { geo in
                    Image(uiImage: photo)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .overlay {
                        ProgressView()
                            .tint(Color.gray)
                    }
            }

            // Year badge
            if let year = entry.photoYear {
                Text("\(year)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(6)
            }
        }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ON THIS DAY")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(red: 0.95, green: 0.3, blue: 0.4))
                .tracking(0.5)

            Text(currentDay)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.black)

            Text(currentMonth)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.gray)
                .tracking(0.5)

            Spacer()

            VStack(spacing: 4) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Add albums in OmniAlbum")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
