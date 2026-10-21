//
//  ImmichAccountView.swift
//  OmniAlbum
//
//  Beta: sign in to an Immich account, sync it to the device, browse the cached timeline.
//

import SwiftUI

struct ImmichAccountView: View {
    let accountID: String
    @StateObject private var viewModel = ImmichAccountViewModel()

    var body: some View {
        AccountTimeline(viewModel: viewModel)
            .navigationTitle(viewModel.activeAccount?.email ?? "Immich")
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.switchAccount(to: accountID) }
    }
}

// MARK: - Viewer plumbing

/// What to show in the viewer: a list of assets, where to start, and whether to play a slideshow.
struct ViewerSelection: Identifiable {
    let id = UUID()
    let assets: [Asset]
    let index: Int
    var slideshow = false
}

extension View {
    /// Full-screen viewer with the system zoom transition from the tile.
    func assetViewer(_ selection: Binding<ViewerSelection?>, source: (any AssetSource)?, namespace: Namespace.ID) -> some View {
        fullScreenCover(item: selection) { sel in
            if let source {
                AssetLightboxView(assets: sel.assets, selectedIndex: sel.index, viewModel: source, zoomNamespace: namespace,
                                  startSlideshow: sel.slideshow, onDismiss: { selection.wrappedValue = nil })
            }
        }
    }
}

// MARK: - Account screen

private enum AccountTab: String, CaseIterable, Identifiable {
    case photos = "Photos", favorites = "Favorites"
    var id: String { rawValue }
}

private struct AccountTimeline: View {
    @ObservedObject var viewModel: ImmichAccountViewModel
    @State private var tab: AccountTab = .photos
    @State private var confirmSignOut = false
    @State private var confirmReset = false
    @State private var viewer: ViewerSelection?
    @State private var showingUpload = false
    @Environment(\.dismiss) private var dismiss
    @Namespace private var zoom

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Section", selection: $tab) {
                ForEach(AccountTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            switch tab {
            case .photos:
                PhotosTimeline(viewModel: viewModel, zoom: zoom, open: openTimeline)
            case .favorites:
                FavoritesGrid(viewModel: viewModel, zoom: zoom, viewer: $viewer)
            }
        }
        .navigationDestination(for: AccountAlbum.self) { AccountAlbumPage(album: $0) }
        .assetViewer($viewer, source: viewModel.assetSource, namespace: zoom)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await viewModel.sync() } }
                    Button("Upload Photos…", systemImage: "square.and.arrow.up") { showingUpload = true }
                    Button("Play Slideshow", systemImage: "play.rectangle") { Task { await playSlideshow() } }
                    Button("Download Everything Again", systemImage: "arrow.counterclockwise") { confirmReset = true }
                    Divider()
                    Button("Sign Out of This Account", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmSignOut = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .sheet(isPresented: $showingUpload) {
            if let account = viewModel.activeAccount {
                UploadQueueSheet(uploadService: .shared, destination: .immich(account: account))
            }
        }
        .confirmationDialog("Sign out of \(viewModel.activeAccount?.email ?? "this account")?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                if let id = viewModel.activeID { Task { await viewModel.signOut(id); dismiss() } }
            }
        } message: {
            Text("The copy of your library on this device is deleted. Your photos on the server aren't touched. Albums from this account leave the Albums tab.")
        }
        .confirmationDialog("Download everything again?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Download Again", role: .destructive) { Task { await viewModel.resetLocalData() } }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                accountLabel
                Spacer()
                if viewModel.isSyncing { ProgressView() }
            }
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(viewModel.errorMessage ?? viewModel.syncError == nil ? Color.secondary : Color.red)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
        .padding(16)
    }

    private var statusLine: String {
        if let error = viewModel.errorMessage ?? viewModel.syncError { return error }
        if viewModel.isSyncing { return "\(viewModel.progress.phase) \(viewModel.progress.linesRead) changes" }
        guard let counts = viewModel.counts else { return "" }
        var line = "\(counts.assets.formatted()) photos & videos · \(counts.albums) album\(counts.albums == 1 ? "" : "s")"
        if let last = viewModel.lastSyncText {
            line += " · synced \(last)"
            if let summary = viewModel.lastSummary { line += summary.applied == 0 ? ", nothing new" : String(format: " (%.1f s)", summary.duration) }
        }
        return line
    }

    private var accountLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(viewModel.activeAccount?.email ?? "").font(.subheadline.weight(.semibold))
            Text(viewModel.activeAccount?.host ?? "").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Opening

    /// Pages through the tapped photo's month and its neighbours.
    private func openTimeline(_ tapped: LibraryAsset) {
        Task {
            guard let (all, index) = await viewModel.viewerAssets(around: tapped) else { return }
            viewer = ViewerSelection(assets: all, index: index)
        }
    }

    /// The newest 1,000 photos.
    private func playSlideshow() async {
        let all = await viewModel.timelineAssets(limit: 1000)
        guard all.count > 1 else { return }
        viewer = ViewerSelection(assets: all, index: 0, slideshow: true)
    }
}

// MARK: - Photos (months)

private struct PhotosTimeline: View {
    @ObservedObject var viewModel: ImmichAccountViewModel
    let zoom: Namespace.ID
    let open: (LibraryAsset) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(viewModel.months, id: \.month) { bucket in
                    Section {
                        MonthGrid(viewModel: viewModel, month: bucket.month, count: bucket.count, columns: columns, zoom: zoom, open: open)
                    } header: {
                        Text(monthTitle(bucket.month))
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
            }
        }
        .refreshable { await viewModel.sync() }
    }

    private func monthTitle(_ month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1])) else { return month }
        return Formatters.monthTitle.string(from: date)
    }
}

/// One month's tiles, read from the local database only when the month scrolls into view.
private struct MonthGrid: View {
    @ObservedObject var viewModel: ImmichAccountViewModel
    let month: String
    let count: Int
    let columns: [GridItem]
    let zoom: Namespace.ID
    let open: (LibraryAsset) -> Void
    @State private var assets: [LibraryAsset] = []

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(assets) { asset in
                Button { open(asset) } label: {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            CachedAsyncImage(url: viewModel.thumbnailURL(asset.id), headers: viewModel.imageHeaders, cacheScope: viewModel.imageCacheScope)
                        }
                        .clipped()
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottomTrailing) {
                            if asset.isVideo {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: asset.id, in: zoom)
            }
        }
        // Reserve the right height before the rows load, so scrolling doesn't jump.
        .frame(minHeight: assets.isEmpty ? CGFloat((count + 2) / 3) * 130 : nil, alignment: .top)
        .task(id: viewModel.dataVersion) { assets = await viewModel.assets(inMonth: month) }
    }
}

// MARK: - Favorites

private struct FavoritesGrid: View {
    @ObservedObject var viewModel: ImmichAccountViewModel
    let zoom: Namespace.ID
    @Binding var viewer: ViewerSelection?
    @State private var assets: [Asset] = []

    var body: some View {
        Group {
            if assets.isEmpty {
                ContentUnavailableView("No Favourites", systemImage: "heart", description: Text("Photos you favourite in Immich appear here."))
            } else if let source = viewModel.assetSource {
                AlbumPhotoGrid(
                    assets: assets, source: source,
                    onRefresh: { await viewModel.sync() },
                    namespace: zoom,
                    onSelect: { asset in
                        if let index = assets.firstIndex(where: { $0.id == asset.id }) { viewer = ViewerSelection(assets: assets, index: index) }
                    },
                    onShare: { asset in Task { try? await AssetActions.share(asset, viewModel: source) } },
                    onSave: { asset in Task { try? await AssetActions.saveToPhotos(asset, viewModel: source) } }
                )
            }
        }
        .task(id: viewModel.dataVersion) { assets = await viewModel.timelineAssets(favoritesOnly: true) }
    }
}
