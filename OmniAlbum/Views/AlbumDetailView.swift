//
//  AlbumDetailView.swift
//  OmniAlbum
//
//  Album detail: native Photos-style grid. Photos and videos open in AssetLightboxView
//  through the system zoom transition.
//

import SwiftUI

private struct LightboxSelection: Identifiable {
    let id: Int
    var slideshow = false
}

struct AlbumDetailView: View {
    let album: DisplayAlbum
    @StateObject private var viewModel: AlbumDetailViewModel
    @ObservedObject private var uploadService = UploadQueueService.shared
    @Namespace private var zoomNamespace
    @State private var lightboxSelection: LightboxSelection?
    @State private var showingAlbumInfo = false
    @State private var showingUploadQueue = false
    @State private var hasAppeared = false
    @State private var actionError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    init(album: DisplayAlbum) {
        self.album = album
        _viewModel = StateObject(wrappedValue: AlbumDetailViewModel(album: album))
    }

    var body: some View {
        mainContent
            .navigationTitle(album.albumName)
            .navigationBarTitleDisplayMode(.inline)
            .albumSubtitle(summaryText)
            // Opaque bar: the grid starts below it and tiles scrolling up are hidden behind it, not shown through it.
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        // Upload button (shows when uploads allowed or uploads exist)
                        if viewModel.allowUpload || !uploadService.uploads(for: album.albumId).isEmpty {
                            Button {
                                showingUploadQueue = true
                            } label: {
                                UploadStatusIcon(uploadService: uploadService, albumId: album.albumId)
                            }
                        }

                        Button {
                            lightboxSelection = LightboxSelection(id: 0, slideshow: true)
                        } label: {
                            Image(systemName: "play.rectangle")
                        }
                        .disabled(viewModel.assets.count < 2)
                        .accessibilityLabel("Play Slideshow")

                        Button {
                            Task { await viewModel.refresh() }
                        } label: {
                            if viewModel.isLoading || viewModel.isRefreshing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(viewModel.isLoading || viewModel.isRefreshing)
                        .accessibilityLabel("Refresh")

                        Button {
                            showingAlbumInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityLabel("Album Info")
                    }
                }
            }
            .sheet(isPresented: $showingAlbumInfo) {
                AlbumInfoSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $showingUploadQueue) {
                UploadQueueSheet(uploadService: uploadService, album: album)
            }
            .fullScreenCover(item: $lightboxSelection) { selection in
                AssetLightboxView(
                    assets: viewModel.assets,
                    selectedIndex: selection.id,
                    viewModel: viewModel,
                    zoomNamespace: zoomNamespace,
                    startSlideshow: selection.slideshow,
                    onDismiss: { lightboxSelection = nil }
                )
            }
            .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            .task {
                let target = deepLinkRouter.consumeTarget()
                await viewModel.loadIfNeeded()
                // Deep link: open the asset
                if let target, target.albumId == album.albumId, let assetId = target.assetId {
                    openAsset(id: assetId)
                }
            }
            .onAppear {
                if hasAppeared {
                    // Refresh in background when view reappears (e.g., after upload)
                    Task { await viewModel.refresh() }
                }
                hasAppeared = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .uploadCompleted)) { notification in
                // Refresh when an upload completes for this album
                if let albumId = notification.userInfo?["albumId"] as? String,
                   albumId == album.albumId {
                    Task { await viewModel.refresh() }
                }
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let error = viewModel.errorMessage {
            errorView(error: error)
        } else if viewModel.assets.isEmpty && viewModel.hasLoaded {
            emptyView
        } else if viewModel.assets.isEmpty {
            SkeletonPhotoGrid()
        } else {
            AlbumPhotoGrid(
                viewModel: viewModel,
                namespace: zoomNamespace,
                onSelect: openInLightbox,
                onShare: { asset in Task { await share(asset) } },
                onSave: { asset in Task { await save(asset) } }
            )
        }
    }

    private var summaryText: String {
        var parts: [String] = []
        if let count = album.assetCount { parts.append(count == 1 ? "1 Photo" : "\(count) Photos") }
        if let range = viewModel.dateRangeText { parts.append(range) }
        if let owner = viewModel.ownerName { parts.append("Shared by \(owner)") }
        return parts.joined(separator: " · ")
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

    // MARK: - Opening

    private func openAsset(id: String) {
        guard let asset = viewModel.assets.first(where: { $0.id == id }) else { return }
        openInLightbox(asset)
    }

    private func openInLightbox(_ asset: Asset) {
        guard let index = viewModel.assets.firstIndex(where: { $0.id == asset.id }) else { return }
        lightboxSelection = LightboxSelection(id: index)
    }

    // MARK: - Tile menu actions

    private func share(_ asset: Asset) async {
        do {
            try await AssetActions.share(asset, viewModel: viewModel)
        } catch {
            actionError = "Failed to load image: \(error.localizedDescription)"
        }
    }

    private func save(_ asset: Asset) async {
        do {
            try await AssetActions.saveToPhotos(asset, viewModel: viewModel)
        } catch {
            actionError = "Failed to save: \(error.localizedDescription)"
        }
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
                if let details = viewModel.albumDetails, details.ownerName != nil {
                    Section("Shared By") {
                        HStack(spacing: 12) {
                            ownerAvatar(
                                name: details.ownerName,
                                avatarColor: details.ownerAvatarColor
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(details.ownerName ?? "Unknown")
                                    .font(.body.weight(.medium))

                                if let email = details.ownerEmail {
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
                if let details = viewModel.albumDetails, !details.sharedUsers.isEmpty {
                    Section("Shared With") {
                        ForEach(details.sharedUsers, id: \.id) { sharedUser in
                            HStack(spacing: 12) {
                                ownerAvatar(
                                    name: sharedUser.name,
                                    avatarColor: sharedUser.avatarColor
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sharedUser.name ?? "Unknown")
                                        .font(.body.weight(.medium))

                                    if let role = sharedUser.role {
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
    private func ownerAvatar(name: String?, avatarColor colorString: String?) -> some View {
        let color = avatarColor(from: colorString)
        let initials = ownerInitials(name)

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


private extension View {
    /// Provider/count/date line under the title (iOS 26+; older systems just get the title).
    @ViewBuilder
    func albumSubtitle(_ text: String) -> some View {
        if #available(iOS 26, *) { navigationSubtitle(text) } else { self }
    }
}
