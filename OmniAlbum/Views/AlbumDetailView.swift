//
//  AlbumDetailView.swift
//  OmniAlbum
//
//  Album detail: a ScatterCore justified grid. Photos open in ScatterCore's own stage/pager;
//  videos open in AssetLightboxView (ScatterCore only renders stills).
//

import SwiftUI
import Photos

private struct LightboxSelection: Identifiable {
    let id: Int
}

struct AlbumDetailView: View {
    let album: DisplayAlbum
    @StateObject private var viewModel: AlbumDetailViewModel
    @ObservedObject private var uploadService = UploadQueueService.shared
    @State private var grid = ScatterGridController()
    @State private var lightboxSelection: LightboxSelection?
    @State private var detailsAsset: Asset?
    @State private var showingAlbumInfo = false
    @State private var showingUploadQueue = false
    @State private var hasAppeared = false
    /// A photo is open in the viewer: hide every bar so it runs edge to edge.
    @State private var isViewing = false
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
            .navigationBarTitleDisplayMode(.large)
            .albumSubtitle(summaryText)
            .background(BarsFader(hidden: isViewing))
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
            .sheet(item: $detailsAsset, onDismiss: { grid.showInfo(false) }) { asset in
                AssetDetailsSheet(asset: asset, viewModel: viewModel)
                    .presentationDetents([.medium, .large])
            }
            .fullScreenCover(item: $lightboxSelection) { selection in
                AssetLightboxView(
                    assets: viewModel.assets,
                    selectedIndex: selection.id,
                    viewModel: viewModel,
                    onDismiss: { lightboxSelection = nil }
                )
                .preferredColorScheme(.dark) // photo/video viewing: black stage, like Photos
            }
            .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            .task {
                let target = deepLinkRouter.consumeTarget()
                await viewModel.loadIfNeeded()
                // Deep link: open the asset (ScatterCore for photos, lightbox for videos)
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
        } else if viewModel.assets.isEmpty && !viewModel.isLoading {
            emptyView
        } else {
            // Full-screen: ScatterCore centres an opened photo in its own bounds, so nothing may sit above it.
            ScatterPhotoGrid(
                viewModel: viewModel,
                controller: grid,
                onVideo: openInLightbox,
                onOpen: { id in withAnimation(.easeInOut(duration: 0.3)) { isViewing = id != nil } },
                onInfo: { asset in
                    detailsAsset = asset
                    grid.showInfo(asset != nil)
                },
                onShare: { asset in Task { await share(asset) } },
                onSave: { asset in Task { await save(asset) } }
            )
            .ignoresSafeArea()
            .overlay {
                if viewModel.isLoading && viewModel.assets.isEmpty {
                    loadingOverlay
                }
            }
            .animation(.easeOut(duration: 0.3), value: viewModel.isLoading)
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

    // MARK: - Opening

    private func openAsset(id: String) {
        guard let asset = viewModel.assets.first(where: { $0.id == id }) else { return }
        if asset.type == .video { openInLightbox(asset) } else { grid.open(id: id) }
    }

    private func openInLightbox(_ asset: Asset) {
        guard let index = viewModel.assets.firstIndex(where: { $0.id == asset.id }) else { return }
        lightboxSelection = LightboxSelection(id: index)
    }

    // MARK: - Tile menu actions

    /// Original bytes (decrypted for Ente), falling back to preview/thumbnail URLs.
    private func originalFile(for asset: Asset) async throws -> URL {
        let data: Data
        if let decrypted = try await viewModel.loadImageData(for: asset, variant: .original) {
            data = decrypted
        } else {
            guard let url = viewModel.originalURL(for: asset) ?? viewModel.previewURL(for: asset) ?? viewModel.thumbnailURL(for: asset) else {
                throw URLError(.badURL)
            }
            data = try await URLSession.shared.data(from: url).0
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(asset.originalFileName)
        try? FileManager.default.removeItem(at: file)
        try data.write(to: file)
        return file
    }

    private func share(_ asset: Asset) async {
        do {
            ShareHelper.share(items: [try await originalFile(for: asset)])
        } catch {
            actionError = "Failed to load image: \(error.localizedDescription)"
        }
    }

    private func save(_ asset: Asset) async {
        do {
            let file = try await originalFile(for: asset)
            defer { try? FileManager.default.removeItem(at: file) }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
            }
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
