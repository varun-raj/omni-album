//
//  AccountAlbumPage.swift
//  OmniAlbum
//
//  One Immich account album, read from that account's local library. Reached from the home Albums
//  list and from the account screen.
//

import SwiftUI

struct AccountAlbumPage: View {
    let album: AccountAlbum
    @ObservedObject private var hub = ImmichHub.shared
    @State private var assets: [Asset] = []
    @State private var viewer: ViewerSelection?
    @State private var actionError: String?
    @Namespace private var zoom

    private var source: AccountAssetSource? { hub.library(for: album.account.id)?.source }

    var body: some View {
        Group {
            if let source {
                AlbumPhotoGrid(
                    assets: assets, source: source,
                    onRefresh: { await hub.sync(album.account.id); assets = await hub.albumAssets(album) },
                    namespace: zoom,
                    onSelect: { asset in
                        if let index = assets.firstIndex(where: { $0.id == asset.id }) { viewer = ViewerSelection(assets: assets, index: index) }
                    },
                    onShare: { asset in Task { await run { try await AssetActions.share(asset, viewModel: source) } } },
                    onSave: { asset in Task { await run { try await AssetActions.saveToPhotos(asset, viewModel: source) } } }
                )
            } else {
                ContentUnavailableView("Account unavailable", systemImage: "person.crop.circle.badge.exclamationmark",
                                       description: Text("Sign in again from Settings → Immich Account."))
            }
        }
        .navigationTitle(album.album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { viewer = ViewerSelection(assets: assets, index: 0, slideshow: true) } label: { Image(systemName: "play.rectangle") }
                    .disabled(assets.count < 2)
                    .accessibilityLabel("Play Slideshow")
            }
        }
        .assetViewer($viewer, source: source, namespace: zoom)
        .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
        .task(id: hub.dataVersion) { assets = await hub.albumAssets(album) }
    }

    private func run(_ work: () async throws -> Void) async {
        do { try await work() } catch { actionError = error.localizedDescription }
    }
}
