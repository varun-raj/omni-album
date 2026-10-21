//
//  ImmichAccountViewModel.swift
//  OmniAlbum
//
//  The account screen: sign-in, which account is active, and its cached timeline. Libraries and syncing
//  live in ImmichHub (so they keep running, and feed the home Albums list, when this screen isn't open).
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class ImmichAccountViewModel: ObservableObject {
    @Published private(set) var accounts: [ImmichAccountInfo] = []
    @Published private(set) var activeID: String?
    @Published private(set) var months: [LibraryStore.MonthBucket] = []
    @Published private(set) var counts: LibraryStore.Counts?
    @Published private(set) var albums: [LibraryAlbum] = []
    @Published private(set) var lastSyncText: String?
    @Published private(set) var isSigningIn = false
    @Published var errorMessage: String?
    /// Changes after each sync or switch so visible month grids re-query.
    @Published private(set) var dataVersion = UUID()

    private let hub: ImmichHub
    private let session: ImmichAccountSession
    private var cancellables = Set<AnyCancellable>()

    init(hub: ImmichHub = .shared, session: ImmichAccountSession = .shared) {
        self.hub = hub
        self.session = session
        accounts = session.accounts
        activeID = session.activeID
        hub.startIfNeeded()

        // Sync status changes and finished syncs come from the hub.
        hub.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        hub.$dataVersion.dropFirst().sink { [weak self] _ in Task { await self?.reload() } }.store(in: &cancellables)
        Task { await reload() } // cached library first: instant
    }

    var activeAccount: ImmichAccountInfo? { accounts.first { $0.id == activeID } }
    private var library: AccountLibrary? { activeID.flatMap(hub.library(for:)) }
    private var status: ImmichHub.SyncStatus? { activeID.flatMap { hub.status[$0] } }

    var isSyncing: Bool { status?.isSyncing ?? false }
    var progress: SyncProgress { status?.progress ?? SyncProgress() }
    var lastSummary: SyncSummary? { status?.summary }
    var syncError: String? { status?.error }

    // MARK: Accounts

    /// Signs in (adding the account if it's new) and switches to it.
    func signIn(server: String, email: String, password: String) async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            let creds = try await ImmichAccountClient.signIn(server: server, email: email, password: password)
            hub.add(creds)
            accounts = session.accounts
            activeID = creds.id
            resetDisplay()
            await reload()
            Task { await hub.sync(creds.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchAccount(to id: String) async {
        guard id != activeID, accounts.contains(where: { $0.id == id }) else { return }
        session.setActive(id)
        activeID = id
        resetDisplay()
        await reload()           // that account's cached library, instantly
        Task { await hub.sync(id) } // other accounts keep syncing in the background
    }

    /// Removes one account and its local copy; switches to another if one is left.
    func signOut(_ id: String) async {
        await hub.remove(id)
        accounts = session.accounts
        if id == activeID {
            activeID = session.activeID
            resetDisplay()
            await reload()
        }
    }

    private func resetDisplay() {
        months = []
        albums = []
        counts = nil
        lastSyncText = nil
        errorMessage = nil
        dataVersion = UUID()
    }

    // MARK: Sync

    func sync() async {
        guard let id = activeID else { return }
        errorMessage = nil
        await hub.sync(id)
    }

    /// Throw away the active account's local copy and download everything again.
    func resetLocalData() async {
        guard let library, let id = activeID else { return }
        await hub.cancelSync(id)
        try? await library.store.wipe()
        // The server's checkpoint is per session, so ask it to start over too.
        try? await library.client.ack(["SyncResetV1|reset"])
        await hub.sync(id)
    }

    // MARK: Reading

    func reload() async {
        guard let store = library?.store else { return }
        months = (try? await store.monthBuckets()) ?? []
        counts = try? await store.counts()
        albums = (try? await store.albums()) ?? []
        if let iso = try? await store.meta("lastSync"), let date = ISO8601DateFormatter().date(from: iso) {
            lastSyncText = date.formatted(.relative(presentation: .named))
        }
        dataVersion = UUID()
    }

    func assets(inMonth month: String) async -> [LibraryAsset] {
        (try? await library?.store.assets(inMonth: month)) ?? []
    }

    /// Everything the viewer pages through, newest first.
    func timelineAssets(favoritesOnly: Bool = false, limit: Int? = nil) async -> [Asset] {
        ((try? await library?.store.timelineAssets(favoritesOnly: favoritesOnly, limit: limit)) ?? []).map(\.asAsset)
    }

    /// What the viewer pages through when a photo is opened from the timeline: its month and the months on
    /// either side. (A real library is hundreds of thousands of photos; loading all of them per tap is too heavy.)
    func viewerAssets(around tapped: LibraryAsset) async -> (assets: [Asset], index: Int)? {
        let month = String(tapped.localDateTime.prefix(7))
        guard let at = months.firstIndex(where: { $0.month == month }) else { return nil }
        var all: [Asset] = []
        for bucket in months[max(0, at - 1)...min(months.count - 1, at + 1)] {
            all += await assets(inMonth: bucket.month).map(\.asAsset)
        }
        guard let index = all.firstIndex(where: { $0.id == tapped.id }) else { return nil }
        return (all, index)
    }

    /// Feeds the shared grid and viewer for the active account.
    var assetSource: AccountAssetSource? { library?.source }
    func thumbnailURL(_ id: String) -> URL? { library?.client.thumbnailURL(assetId: id) }
    var imageHeaders: [String: String]? { library?.client.authHeaders }
    var imageCacheScope: String? { library?.client.cacheScope }
}
