//
//  ContentView.swift
//  OmniAlbum
//
//  Album view with grid and list modes, styled like Apple Photos.
//

import SwiftUI

enum AlbumViewMode: String {
    case grid
    case list
}

struct ContentView: View {
    @StateObject private var viewModel = AggregatorViewModel()
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter
    @State private var navigationPath = NavigationPath()
    @State private var showAddSheet = false
    @State private var albumToDelete: DisplayAlbum?
    @State private var searchText = ""
    @AppStorage("albumViewMode") private var viewMode: AlbumViewMode = .grid
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let gridSpacing: CGFloat = 12
    private static let gridPadding: CGFloat = 16
    private static let albumCornerRadius: CGFloat = 20

    /// Adaptive column count based on size class
    private var albumGridColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing), count: count)
    }

    /// Filtered albums based on search text
    private var filteredAlbums: [DisplayAlbum] {
        if searchText.isEmpty {
            return viewModel.albums
        }
        let query = searchText.lowercased()
        return viewModel.albums.filter { album in
            album.albumName.lowercased().contains(query) ||
            album.baseURL.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if viewModel.isLoading && viewModel.albums.isEmpty {
                    loadingView
                } else if viewModel.albums.isEmpty {
                    emptyState
                } else {
                    albumsContent
                }
            }
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search albums")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !viewModel.albums.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewMode = viewMode == .grid ? .list : .grid
                            }
                        } label: {
                            Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .accessibilityLabel(viewMode == .grid ? "Show as List" : "Show as Grid")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Album")
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddAlbumSheet(isPresented: $showAddSheet, viewModel: viewModel) {
                    showAddSheet = false
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(albumToDelete?.albumName ?? "")\"?",
            isPresented: Binding(get: { albumToDelete != nil }, set: { if !$0 { albumToDelete = nil } }),
            titleVisibility: .visible,
            presenting: albumToDelete
        ) { album in
            Button("Delete Album", role: .destructive) {
                Task { await viewModel.deleteAlbum(album) }
            }
        } message: { _ in
            Text("This removes the album from OmniAlbum. The photos on the server aren't affected.")
        }
        // A link can arrive before the list has loaded: try again when either side changes.
        .onChange(of: deepLinkRouter.pendingTarget?.albumId) { _, _ in openPendingDeepLink() }
        .onChange(of: viewModel.albums.map(\.id)) { _, _ in openPendingDeepLink() }
        .onChange(of: viewModel.isLoading) { _, _ in openPendingDeepLink() }
        .onChange(of: viewModel.isSyncing) { _, _ in openPendingDeepLink() }
        .onAppear { openPendingDeepLink() }
    }

    /// Pushes the album named by a pending deep link. The target stays pending until the album exists
    /// (AlbumDetailView consumes it); if the lists have finished loading and it never shows up, it's dropped.
    private func openPendingDeepLink() {
        guard let target = deepLinkRouter.pendingTarget else { return }
        if let album = viewModel.albums.first(where: { $0.albumId == target.albumId }) {
            navigationPath = NavigationPath([album])
        } else if !viewModel.isLoading && !viewModel.isSyncing {
            _ = deepLinkRouter.consumeTarget()
        }
    }

    private var loadingView: some View {
        SkeletonAlbumGrid()
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer()
                    .frame(height: 20)

                // App icon / hero
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                VStack(spacing: 8) {
                    Text("Welcome to OmniAlbum")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("View shared albums from your favorite\nself-hosted photo services.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Provider icons row
                HStack(spacing: 16) {
                    ForEach(PhotoProvider.allCases, id: \.self) { provider in
                        providerPill(provider)
                    }
                }
                .padding(.horizontal)

                // CTA
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Share Link", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: 260)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .scrollIndicators(.hidden)
    }

    private func providerPill(_ provider: PhotoProvider) -> some View {
        VStack(spacing: 6) {
            if let logoAsset = provider.logoAssetName {
                Image(logoAsset)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 9))
            } else {
                Image(systemName: provider.iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(provider.accentColor, in: .rect(cornerRadius: 9))
            }
            Text(provider.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var albumsContent: some View {
        Group {
            switch viewMode {
            case .grid:
                gridView
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .list:
                listView
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewMode)
        .navigationDestination(for: DisplayAlbum.self) { album in
            AlbumDetailView(album: album)
        }
    }

    private var gridView: some View {
        ScrollView {
            if filteredAlbums.isEmpty && !searchText.isEmpty {
                noSearchResultsView
            } else {
                LazyVGrid(columns: albumGridColumns, spacing: Self.gridSpacing) {
                    ForEach(filteredAlbums) { album in
                        NavigationLink(value: album) {
                            AlbumGridCell(album: album, cornerRadius: Self.albumCornerRadius)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { albumMenu(album) }
                    }
                }
                .padding(Self.gridPadding)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var listView: some View {
        List {
            if filteredAlbums.isEmpty && !searchText.isEmpty {
                noSearchResultsView
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } else {
                ForEach(filteredAlbums) { album in
                    NavigationLink(value: album) {
                        AlbumListCell(album: album)
                    }
                    .contextMenu { albumMenu(album) }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                }
                .onDelete { indexSet in
                    albumToDelete = indexSet.first.map { filteredAlbums[$0] }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.refresh()
        }
    }

    @ViewBuilder
    private func albumMenu(_ album: DisplayAlbum) -> some View {
        Button("Copy Link", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = album.shareLink
        }
        ShareLink(item: album.shareLink) {
            Label("Share Link", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            albumToDelete = album
        }
    }

    private var noSearchResultsView: some View {
        ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 60)
    }
}

// MARK: - Album Grid Cell

/// Square rounded card: cover photo with the name, count, provider and status icons overlaid. No shadows.
struct AlbumGridCell: View {
    let album: DisplayAlbum
    var cornerRadius: CGFloat = 20

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { cover }
            .overlay(alignment: .bottomLeading) { caption }
            .overlay(alignment: .topLeading) {
                ProviderBadge(provider: album.provider, size: 26)
                    .padding(10)
            }
            .overlay(alignment: .topTrailing) { statusIcons }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .contentShape(.rect(cornerRadius: cornerRadius))
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var cover: some View {
        if let url = AggregatorViewModel.thumbnailURL(for: album) {
            CachedAsyncImage(url: url)
        } else {
            Rectangle()
                .fill(Color(.systemGray5))
                .overlay {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
        }
    }

    /// Name and count over a bottom scrim so white text reads on any photo.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(album.albumName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(albumCountLabel(album.assetCount))
                .font(.caption)
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        )
    }

    private var statusIcons: some View {
        HStack(spacing: 6) {
            if album.password != nil {
                chip("lock.fill", label: "Password protected")
            }
            if album.allowUpload {
                chip("arrow.up", label: "Uploads allowed")
            }
        }
        .padding(10)
    }

    private func chip(_ symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(.black.opacity(0.35), in: Circle())
            .background(.ultraThinMaterial, in: Circle())
            .accessibilityLabel(label)
    }

    private func albumCountLabel(_ count: Int?) -> String {
        guard let count else { return "No photos" }
        return count == 1 ? "1 Photo" : "\(count) Photos"
    }
}

// MARK: - Album List Cell

struct AlbumListCell: View {
    let album: DisplayAlbum

    var body: some View {
        HStack(spacing: 14) {
            cover
                .frame(width: 76, height: 76)
                .clipShape(.rect(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 4) {
                Text(album.albumName)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(albumCountLabel(album.assetCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if album.password != nil {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Password protected")
                    }
                    if album.allowUpload {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .accessibilityLabel("Uploads allowed")
                    }
                    if !album.allowDownload {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Downloads disabled")
                    }
                }

                HStack(spacing: 6) {
                    ProviderBadge(provider: album.provider, size: 14)
                    Text(serverDisplayName(album.baseURL))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 26))
        .accessibilityElement(children: .combine)
    }

    private func albumCountLabel(_ count: Int?) -> String {
        guard let count else { return "No photos" }
        return count == 1 ? "1 Photo" : "\(count) Photos"
    }

    private func serverDisplayName(_ baseURL: String) -> String {
        URL(string: baseURL)?.host ?? baseURL
    }

    @ViewBuilder
    private var cover: some View {
        if let url = AggregatorViewModel.thumbnailURL(for: album) {
            CachedAsyncImage(url: url)
        } else {
            Rectangle()
                .fill(Color(.systemGray5))
                .overlay {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
        }
    }
}

// MARK: - Provider Badge

struct ProviderBadge: View {
    let provider: PhotoProvider
    var size: CGFloat = 20

    var body: some View {
        badge.accessibilityLabel(provider.displayName)
    }

    @ViewBuilder
    private var badge: some View {
        if let logoAsset = provider.logoAssetName {
            Image(logoAsset)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.22))
        } else {
            Image(systemName: provider.iconName)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(provider.accentColor, in: .rect(cornerRadius: size * 0.22))
        }
    }
}

#Preview {
    ContentView()
}
