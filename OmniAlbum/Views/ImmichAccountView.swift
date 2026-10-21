//
//  ImmichAccountView.swift
//  OmniAlbum
//
//  Beta: sign in to an Immich account, sync it to the device, browse the cached timeline.
//

import SwiftUI

struct ImmichAccountView: View {
    @StateObject private var viewModel = ImmichAccountViewModel()

    var body: some View {
        Group {
            if viewModel.activeAccount == nil {
                SignInForm(viewModel: viewModel)
            } else {
                AccountTimeline(viewModel: viewModel)
            }
        }
        .navigationTitle("Immich Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sign in

private struct SignInForm: View {
    @ObservedObject var viewModel: ImmichAccountViewModel
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""

    private var canSignIn: Bool { !server.isEmpty && !email.isEmpty && !password.isEmpty && !viewModel.isSigningIn }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Sign in to browse your whole library, not just shared links. It's copied to this device once, then only changes sync.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                field("Server", symbol: "server.rack") {
                    TextField("https://photos.example.com", text: $server)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                field("Email", symbol: "envelope") {
                    TextField("you@example.com", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                field("Password", symbol: "lock") {
                    SecureField("Password", text: $password).textContentType(.password)
                }

                Text("Syncing needs a normal sign-in. Immich doesn't allow API keys to sync.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: .rect(cornerRadius: 16))
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await viewModel.signIn(server: server, email: email, password: password) }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isSigningIn { ProgressView().tint(.white) }
                    Text(viewModel.isSigningIn ? "Signing in…" : "Sign In").font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!canSignIn)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func field<Content: View>(_ title: String, symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
        }
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

private extension View {
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
    case photos = "Photos", albums = "Albums", favorites = "Favorites"
    var id: String { rawValue }
}

private struct AccountTimeline: View {
    @ObservedObject var viewModel: ImmichAccountViewModel
    @State private var tab: AccountTab = .photos
    @State private var confirmSignOut = false
    @State private var confirmReset = false
    @State private var showingAddAccount = false
    @State private var viewer: ViewerSelection?
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
            case .albums:
                AlbumsGrid(viewModel: viewModel)
            case .favorites:
                FavoritesGrid(viewModel: viewModel, zoom: zoom, viewer: $viewer)
            }
        }
        .navigationDestination(for: LibraryAlbum.self) { AccountAlbumView(viewModel: viewModel, album: $0) }
        .assetViewer($viewer, source: viewModel.assetSource, namespace: zoom)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await viewModel.sync() } }
                    Button("Play Slideshow", systemImage: "play.rectangle") { Task { await playSlideshow() } }
                    Button("Download Everything Again", systemImage: "arrow.counterclockwise") { confirmReset = true }
                    Divider()
                    Button("Sign Out of This Account", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmSignOut = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .sheet(isPresented: $showingAddAccount) {
            NavigationStack {
                SignInForm(viewModel: viewModel)
                    .navigationTitle("Add Account")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingAddAccount = false } } }
            }
            .onChange(of: viewModel.activeID) { _, _ in showingAddAccount = false } // signing in switches to the new account
        }
        .confirmationDialog("Sign out of \(viewModel.activeAccount?.email ?? "this account")?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                if let id = viewModel.activeID { Task { await viewModel.signOut(id) } }
            }
        } message: {
            Text("The copy of your library on this device is deleted. Your photos on the server aren't touched.")
        }
        .confirmationDialog("Download everything again?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Download Again", role: .destructive) { Task { await viewModel.resetLocalData() } }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                accountSwitcher
                Spacer()
                if viewModel.isSyncing { ProgressView() }
            }
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(viewModel.errorMessage == nil ? Color.secondary : Color.red)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
        .padding(16)
    }

    private var statusLine: String {
        if let error = viewModel.errorMessage { return error }
        if viewModel.isSyncing { return "\(viewModel.progress.phase) \(viewModel.progress.linesRead) changes" }
        guard let counts = viewModel.counts else { return "" }
        var line = "\(counts.assets.formatted()) photos & videos · \(counts.albums) album\(counts.albums == 1 ? "" : "s")"
        if let last = viewModel.lastSyncText {
            line += " · synced \(last)"
            if let summary = viewModel.lastSummary { line += summary.applied == 0 ? ", nothing new" : String(format: " (%.1f s)", summary.duration) }
        }
        return line
    }

    /// Current account; tap to switch to another signed-in account or add one.
    private var accountSwitcher: some View {
        Menu {
            ForEach(viewModel.accounts) { account in
                Button {
                    Task { await viewModel.switchAccount(to: account.id) }
                } label: {
                    if account.id == viewModel.activeID {
                        Label("\(account.email) · \(account.host)", systemImage: "checkmark")
                    } else {
                        Text("\(account.email) · \(account.host)")
                    }
                }
            }
            Divider()
            Button("Add Account…", systemImage: "plus") { showingAddAccount = true }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.activeAccount?.email ?? "").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(viewModel.activeAccount?.host ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .tint(.primary) // menu labels would otherwise take the accent colour
        .accessibilityLabel("Account: \(viewModel.activeAccount?.email ?? ""). Switch account")
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

// MARK: - Albums

private struct AlbumsGrid: View {
    @ObservedObject var viewModel: ImmichAccountViewModel
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        if viewModel.albums.isEmpty {
            ContentUnavailableView("No Albums", systemImage: "rectangle.stack", description: Text("Albums you own or that are shared with you appear here."))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewModel.albums) { album in
                        NavigationLink(value: album) { card(album) }.buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .refreshable { await viewModel.sync() }
        }
    }

    private func card(_ album: LibraryAlbum) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let id = album.thumbnailAssetId {
                    CachedAsyncImage(url: viewModel.thumbnailURL(id), headers: viewModel.imageHeaders, cacheScope: viewModel.imageCacheScope)
                } else {
                    Rectangle().fill(Color(.systemGray5)).overlay { Image(systemName: "photo.on.rectangle").foregroundStyle(.tertiary) }
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text("\(album.assetCount) item\(album.assetCount == 1 ? "" : "s")").font(.caption).opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(.rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
            .accessibilityElement(children: .combine)
    }
}

/// One album's photos from the local database.
private struct AccountAlbumView: View {
    @ObservedObject var viewModel: ImmichAccountViewModel
    let album: LibraryAlbum
    @State private var assets: [Asset] = []
    @State private var viewer: ViewerSelection?
    @State private var actionError: String?
    @Namespace private var zoom

    var body: some View {
        Group {
            if let source = viewModel.assetSource {
                AlbumPhotoGrid(
                    assets: assets, source: source,
                    onRefresh: { await viewModel.sync(); assets = await viewModel.albumAssets(album.id) },
                    namespace: zoom,
                    onSelect: { asset in
                        if let index = assets.firstIndex(where: { $0.id == asset.id }) { viewer = ViewerSelection(assets: assets, index: index) }
                    },
                    onShare: { asset in Task { await run { try await AssetActions.share(asset, viewModel: source) } } },
                    onSave: { asset in Task { await run { try await AssetActions.saveToPhotos(asset, viewModel: source) } } }
                )
            }
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { viewer = ViewerSelection(assets: assets, index: 0, slideshow: true) } label: { Image(systemName: "play.rectangle") }
                    .disabled(assets.count < 2)
                    .accessibilityLabel("Play Slideshow")
            }
        }
        .assetViewer($viewer, source: viewModel.assetSource, namespace: zoom)
        .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
        .task(id: viewModel.dataVersion) { assets = await viewModel.albumAssets(album.id) }
    }

    private func run(_ work: () async throws -> Void) async {
        do { try await work() } catch { actionError = error.localizedDescription }
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
