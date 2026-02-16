//
//  ContentView.swift
//  immich-share
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
    @State private var showAddSheet = false
    @State private var searchText = ""
    @AppStorage("albumViewMode") private var viewMode: AlbumViewMode = .grid

    private static let gridSpacing: CGFloat = 16
    private static let gridPadding: CGFloat = 16
    private static let albumCornerRadius: CGFloat = 12

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
        NavigationStack {
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
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddAlbumSheet(isPresented: $showAddSheet, viewModel: viewModel) {
                    showAddSheet = false
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading albums...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Albums", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Add an Immich share link to see albums here.")
        } actions: {
            Button("Add Share Link") {
                showAddSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var albumsContent: some View {
        Group {
            switch viewMode {
            case .grid:
                gridView
            case .list:
                listView
            }
        }
        .navigationDestination(for: DisplayAlbum.self) { album in
            AlbumDetailView(album: album)
        }
    }

    private var gridView: some View {
        ScrollView {
            if filteredAlbums.isEmpty && !searchText.isEmpty {
                noSearchResultsView
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: Self.gridSpacing),
                    GridItem(.flexible(), spacing: Self.gridSpacing)
                ], spacing: Self.gridSpacing) {
                    ForEach(filteredAlbums) { album in
                        NavigationLink(value: album) {
                            AlbumGridCell(album: album, cornerRadius: Self.albumCornerRadius)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Self.gridPadding)
            }
        }
        .scrollIndicators(.hidden)
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
                }
                .onDelete { indexSet in
                    Task {
                        for index in indexSet {
                            let album = filteredAlbums[index]
                            await viewModel.deleteAlbum(album)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var noSearchResultsView: some View {
        ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 60)
    }
}

// MARK: - Album Grid Cell

struct AlbumGridCell: View {
    let album: DisplayAlbum
    var cornerRadius: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailView
            VStack(alignment: .leading, spacing: 2) {
                Text(album.albumName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Text(albumCountLabel(album.assetCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
    }

    private func albumCountLabel(_ count: Int?) -> String {
        guard let count else { return "No photos" }
        return count == 1 ? "1 Photo" : "\(count) Photos"
    }

    @ViewBuilder
    private var thumbnailView: some View {
        let url = AggregatorViewModel.thumbnailURL(
            baseURL: album.baseURL,
            assetId: album.albumThumbnailAssetId ?? "",
            shareKey: album.shareKey
        )
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Group {
                    if let url = url, !(album.albumThumbnailAssetId ?? "").isEmpty {
                        CachedAsyncImage(url: url)
                    } else {
                        placeholderImage
                    }
                }
            }
            .clipped()
            .clipShape(.rect(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
    }

    private var placeholderImage: some View {
        Rectangle()
            .fill(Color(.systemGray5))
            .overlay {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}

// MARK: - Album List Cell

struct AlbumListCell: View {
    let album: DisplayAlbum

    var body: some View {
        HStack(spacing: 14) {
            // Thumbnail
            thumbnailView
                .frame(width: 70, height: 70)
                .clipShape(.rect(cornerRadius: 10))

            // Album info
            VStack(alignment: .leading, spacing: 4) {
                Text(album.albumName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(albumCountLabel(album.assetCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if album.allowUpload {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }

                    if !album.allowDownload {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !album.showMetadata {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if album.password != nil {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // Server URL (truncated)
                Text(serverDisplayName(album.baseURL))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func albumCountLabel(_ count: Int?) -> String {
        guard let count else { return "No photos" }
        return count == 1 ? "1 Photo" : "\(count) Photos"
    }

    private func serverDisplayName(_ baseURL: String) -> String {
        guard let url = URL(string: baseURL), let host = url.host else {
            return baseURL
        }
        return host
    }

    @ViewBuilder
    private var thumbnailView: some View {
        let url = AggregatorViewModel.thumbnailURL(
            baseURL: album.baseURL,
            assetId: album.albumThumbnailAssetId ?? "",
            shareKey: album.shareKey
        )

        if let url = url, !(album.albumThumbnailAssetId ?? "").isEmpty {
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

#Preview {
    ContentView()
}
