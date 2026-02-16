//
//  AlbumDetailView.swift
//  immich-share
//
//  Album detail styled like Apple Photos: full-width hero header, dense grid.
//

import SwiftUI
import Kingfisher

private struct LightboxSelection: Identifiable {
    let id: Int
}

struct AlbumDetailView: View {
    let album: DisplayAlbum
    @StateObject private var viewModel: AlbumDetailViewModel
    @ObservedObject private var uploadService = UploadQueueService.shared
    @State private var lightboxSelection: LightboxSelection?
    @State private var scrollOffset: CGFloat = 0
    @State private var showingAlbumInfo = false
    @State private var showingUploadQueue = false
    @State private var navigateToUpload = false
    @State private var hasAppeared = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(album: DisplayAlbum) {
        self.album = album
        _viewModel = StateObject(wrappedValue: AlbumDetailViewModel(album: album))
    }

    private static let gridSpacing: CGFloat = 2
    private static let headerHeight: CGFloat = 380

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing), count: 3)
    }

    // Nav bar title fades in as header title fades out
    private var navBarOpacity: Double {
        let fadeStart: CGFloat = 140
        let fadeEnd: CGFloat = 200
        if scrollOffset < fadeStart { return 0.0 }
        if scrollOffset > fadeEnd { return 1.0 }
        return Double((scrollOffset - fadeStart) / (fadeEnd - fadeStart))
    }

    private var navBarBackgroundOpacity: Double {
        let fadeStart: CGFloat = 180
        let fadeEnd: CGFloat = 220
        if scrollOffset < fadeStart { return 0.0 }
        if scrollOffset > fadeEnd { return 1.0 }
        return Double((scrollOffset - fadeStart) / (fadeEnd - fadeStart))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                mainContent(geometry: geometry)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(navBarBackgroundOpacity > 0.5 ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(album.albumName)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(navBarOpacity)
                    .scaleEffect(0.9 + (navBarOpacity * 0.1))
                    .animation(.easeOut(duration: 0.15), value: navBarOpacity)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    // Upload status button (shows when there are uploads for this album)
                    if !uploadService.uploads(for: album.albumId).isEmpty {
                        Button {
                            showingUploadQueue = true
                        } label: {
                            UploadStatusIcon(uploadService: uploadService, albumId: album.albumId)
                        }
                    }

                    if viewModel.allowUpload {
                        NavigationLink(destination: PhotoPickerView(album: album)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }

                    Button {
                        showingAlbumInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAlbumInfo) {
            AlbumInfoSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingUploadQueue) {
            UploadQueueSheet(uploadService: uploadService, albumId: album.albumId)
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .onAppear {
            if hasAppeared {
                // Refresh in background when view reappears (e.g., after upload)
                Task {
                    await viewModel.refresh()
                }
            }
            hasAppeared = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .uploadCompleted)) { notification in
            // Refresh when an upload completes for this album
            if let albumId = notification.userInfo?["albumId"] as? String,
               albumId == album.albumId {
                Task {
                    await viewModel.refresh()
                }
            }
        }
    }

    @ViewBuilder
    private func mainContent(geometry: GeometryProxy) -> some View {
        if let error = viewModel.errorMessage {
            errorView(error: error)
        } else if viewModel.assets.isEmpty && !viewModel.isLoading {
            emptyView
        } else {
            photoGridContent(geometry: geometry)
        }
    }

    private func errorView(error: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Load Photos", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Try Again") {
                Task { await viewModel.loadIfNeeded() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No Photos", systemImage: "photo")
        } description: {
            Text("This album has no photos yet.")
        }
    }

    private func photoGridContent(geometry: GeometryProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                // Hero header
                albumHeader(geometry: geometry)

                // Photo grid
                photoGrid
                    .padding(.top, 2)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: -proxy.frame(in: .named("scroll")).minY
                        )
                }
            )
        }
        .coordinateSpace(name: "scroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            scrollOffset = value
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(.container, edges: .top)
        .fullScreenCover(item: $lightboxSelection) { selection in
            AssetLightboxView(
                assets: viewModel.assets,
                selectedIndex: selection.id,
                viewModel: viewModel,
                onDismiss: { lightboxSelection = nil }
            )
        }
        .overlay {
            if viewModel.isLoading && viewModel.assets.isEmpty {
                loadingOverlay
            }
        }
        .animation(.easeOut(duration: 0.3), value: viewModel.isLoading)
    }

    private func albumHeader(geometry: GeometryProxy) -> some View {
        let headerWidth = geometry.size.width
        let safeAreaTop = geometry.safeAreaInsets.top
        let baseHeight = Self.headerHeight + safeAreaTop

        // Parallax calculations
        // When pulling down (scrollOffset < 0), stretch the header
        // When scrolling up (scrollOffset > 0), parallax effect
        let pullDown = max(0, -scrollOffset)
        let scrollUp = max(0, scrollOffset)

        // Header stretches when pulling down
        let headerHeight = baseHeight + pullDown

        // Parallax: image moves slower than scroll (creates depth effect)
        let parallaxMultiplier: CGFloat = 0.5
        let imageOffset = scrollUp * parallaxMultiplier

        // Extra height for parallax movement room
        let imageHeight = headerHeight + 150

        return ZStack(alignment: .bottomLeading) {
            // Hero image with parallax (high quality preview)
            if let coverURL = viewModel.coverImageURL {
                KFImage(coverURL)
                    .placeholder {
                        // Show thumbnail as placeholder while loading high-res
                        if let thumbnailId = album.albumThumbnailAssetId {
                            KFImage(AggregatorViewModel.thumbnailURL(
                                baseURL: album.baseURL,
                                assetId: thumbnailId,
                                shareKey: album.shareKey
                            ))
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle()
                                .fill(Color(.systemGray5))
                        }
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: headerWidth, height: imageHeight)
                    .offset(y: -imageOffset)
                    .frame(width: headerWidth, height: headerHeight, alignment: .top)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(width: headerWidth, height: headerHeight)
                    .overlay {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 60))
                            .foregroundStyle(.tertiary)
                    }
            }

            // Gradient overlay for text readability - top and bottom
            ZStack {
                // Top gradient for navigation bar visibility
                LinearGradient(
                    colors: [
                        .black.opacity(0.4),
                        .black.opacity(0.2),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )

                // Bottom gradient for album info visibility
                LinearGradient(
                    colors: [
                        .clear,
                        .clear,
                        .black.opacity(0.2),
                        .black.opacity(0.6)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            // Album info overlay with fade and translate animation
            VStack(alignment: .leading, spacing: 8) {
                Text(album.albumName)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)

                // Owner info
                if let ownerName = viewModel.ownerName {
                    HStack(spacing: 6) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 14))
                        Text("Shared by \(ownerName)")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)
                }

                // Photo count and date range
                HStack(spacing: 6) {
                    if let count = album.assetCount {
                        Text(photoCountText(count))
                            .font(.subheadline.weight(.medium))
                    }

                    if let dateRange = viewModel.dateRangeText {
                        Text("•")
                            .font(.caption)
                        Text(dateRange)
                            .font(.subheadline.weight(.medium))
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)

                // Share link button
                Button {
                    if let url = URL(string: viewModel.shareURL) {
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Open in Browser")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.2), in: Capsule())
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .opacity(titleOverlayOpacity)
            .offset(y: titleOffset)
        }
        .frame(width: headerWidth, height: headerHeight)
        .clipped()
    }

    // Title fades out and moves up as it transitions to nav bar
    private var titleOverlayOpacity: Double {
        let fadeStart: CGFloat = 80
        let fadeEnd: CGFloat = 180
        if scrollOffset < fadeStart { return 1.0 }
        if scrollOffset > fadeEnd { return 0.0 }
        return 1.0 - Double((scrollOffset - fadeStart) / (fadeEnd - fadeStart))
    }

    private var titleOffset: CGFloat {
        let moveStart: CGFloat = 80
        if scrollOffset < moveStart { return 0 }
        // Move up as we scroll
        return -(scrollOffset - moveStart) * 0.3
    }

    private var photoGrid: some View {
        LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
            ForEach(viewModel.assets.indices, id: \.self) { index in
                let asset = viewModel.assets[index]
                Button {
                    lightboxSelection = LightboxSelection(id: index)
                } label: {
                    PhotoGridCell(
                        url: viewModel.thumbnailURL(for: asset),
                        isVideo: asset.type.lowercased() == "video",
                        duration: asset.duration
                    )
                }
                .buttonStyle(PhotoGridButtonStyle())
            }
        }
        .padding(.horizontal, Self.gridSpacing)
        .padding(.bottom, 20)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.secondary)

            Text("Loading photos…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .transition(.opacity.animation(.easeOut(duration: 0.3)))
    }

    private func photoCountText(_ count: Int) -> String {
        count == 1 ? "1 Photo" : "\(count) Photos"
    }
}

// MARK: - Photo Grid Cell

private struct PhotoGridCell: View {
    let url: URL?
    let isVideo: Bool
    let duration: String?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                CachedAsyncImage(url: url)
            }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                if isVideo {
                    videoBadge
                }
            }
    }

    private var videoBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .semibold))
            if let duration = duration, !duration.isEmpty, duration != "0:00:00" {
                Text(formattedDuration(duration))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(6)
    }

    private func formattedDuration(_ duration: String) -> String {
        // Duration comes as "H:MM:SS", convert to M:SS format (minutes and seconds only)
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return duration }

        if parts.count == 3 {
            let hours = parts[0]
            let minutes = parts[1]
            let seconds = parts[2]
            // Convert hours to minutes and add to minutes
            let totalMinutes = hours * 60 + minutes
            return String(format: "%d:%02d", totalMinutes, seconds)
        } else if parts.count == 2 {
            return String(format: "%d:%02d", parts[0], parts[1])
        }
        return duration
    }
}

// MARK: - Custom Button Style for Grid

private struct PhotoGridButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Scroll Offset Preference Key

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Album Info Sheet

private struct AlbumInfoSheet: View {
    @ObservedObject var viewModel: AlbumDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fallbackIsoFormatter = ISO8601DateFormatter()

    var body: some View {
        NavigationStack {
            List {
                // Album name and description
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(viewModel.album.albumName)
                            .font(.title2.weight(.bold))

                        if let description = viewModel.albumDescription {
                            Text(description)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
                }

                // Owner
                if let details = viewModel.albumDetails {
                    Section("Shared By") {
                        HStack(spacing: 12) {
                            ownerAvatar(for: details.owner)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(details.owner.name ?? "Unknown")
                                    .font(.body.weight(.medium))

                                if let email = details.owner.email {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Stats
                Section("Details") {
                    if let count = viewModel.album.assetCount {
                        LabeledContent("Photos & Videos", value: "\(count)")
                    }

                    if let dateRange = viewModel.dateRangeText {
                        LabeledContent("Date Range", value: dateRange)
                    }

                    if let details = viewModel.albumDetails {
                        if let createdAt = parseDate(details.createdAt) {
                            LabeledContent("Created", value: Self.dateFormatter.string(from: createdAt))
                        }

                        if let updatedAt = parseDate(details.updatedAt) {
                            LabeledContent("Last Updated", value: Self.dateFormatter.string(from: updatedAt))
                        }
                    }
                }

                // Share link
                Section("Share Link") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(viewModel.shareURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)

                        HStack(spacing: 12) {
                            Button {
                                UIPasteboard.general.string = viewModel.shareURL
                            } label: {
                                Label("Copy Link", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                if let url = URL(string: viewModel.shareURL) {
                                    openURL(url)
                                }
                            } label: {
                                Label("Open", systemImage: "safari")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Album users (if any)
                if let details = viewModel.albumDetails, !details.albumUsers.isEmpty {
                    Section("Shared With") {
                        ForEach(details.albumUsers, id: \.user?.id) { albumUser in
                            if let user = albumUser.user {
                                HStack(spacing: 12) {
                                    ownerAvatar(for: user)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(user.name ?? "Unknown")
                                            .font(.body.weight(.medium))

                                        if let role = albumUser.role {
                                            Text(role.capitalized)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Album Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func ownerAvatar(for owner: AlbumOwner) -> some View {
        let color = avatarColor(from: owner.avatarColor)
        let initials = ownerInitials(owner.name)

        Circle()
            .fill(color.gradient)
            .frame(width: 40, height: 40)
            .overlay {
                Text(initials)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private func avatarColor(from colorString: String?) -> Color {
        guard let colorString = colorString?.lowercased() else { return .blue }

        switch colorString {
        case "red": return .red
        case "pink": return .pink
        case "purple": return .purple
        case "blue": return .blue
        case "cyan": return .cyan
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "gray", "grey": return .gray
        case "brown": return .brown
        default:
            // Try to parse as hex
            if colorString.hasPrefix("#") {
                return Color(hex: colorString) ?? .blue
            }
            return .blue
        }
    }

    private func ownerInitials(_ name: String?) -> String {
        guard let name = name, !name.isEmpty else { return "?" }
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func parseDate(_ dateString: String) -> Date? {
        Self.isoFormatter.date(from: dateString) ?? Self.fallbackIsoFormatter.date(from: dateString)
    }
}

// MARK: - Color Extension for Hex

private extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}
