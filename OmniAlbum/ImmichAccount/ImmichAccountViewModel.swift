//
//  ImmichAccountViewModel.swift
//  OmniAlbum
//
//  Accounts, sync and the cached timeline for Immich. Several accounts can be signed in; switching
//  opens that account's own local library (shown instantly) and then catches up in the background.
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
    @Published private(set) var isSyncing = false
    @Published private(set) var progress = SyncProgress()
    @Published private(set) var lastSummary: SyncSummary?
    @Published private(set) var isSigningIn = false
    @Published var errorMessage: String?
    /// Changes after each sync or switch so visible month grids re-query.
    @Published private(set) var dataVersion = UUID()

    private let session: ImmichAccountSession
    private var store: LibraryStore?
    private(set) var client: ImmichAccountClient?
    /// Feeds the shared grid and viewer for the active account.
    private(set) var assetSource: AccountAssetSource?
    private var syncTask: Task<Void, Never>?

    init(session: ImmichAccountSession = .shared) {
        self.session = session
        accounts = session.accounts
        if let creds = session.activeCredentials {
            open(creds)
            Task {
                await reload()   // cached library first: instant
                await sync()     // then catch up
            }
        }
    }

    var activeAccount: ImmichAccountInfo? { accounts.first { $0.id == activeID } }

    // MARK: Accounts

    /// Signs in (adding the account if it's new) and switches to it.
    func signIn(server: String, email: String, password: String) async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            let creds = try await ImmichAccountClient.signIn(server: server, email: email, password: password)
            await stopSync()
            session.add(creds)
            accounts = session.accounts
            open(creds)
            await reload()
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchAccount(to id: String) async {
        guard id != activeID, let creds = session.credentials(for: id) else { return }
        await stopSync()
        session.setActive(id)
        resetDisplay()
        open(creds)
        await reload()
        await sync()
    }

    /// Removes one account and its local copy; switches to another if one is left.
    func signOut(_ id: String) async {
        await stopSync()
        if let path = try? LibraryStore.defaultPath(for: id) {
            if id == activeID { store = nil }
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let wasActive = id == activeID
        session.remove(id)
        accounts = session.accounts
        guard wasActive else { return }
        resetDisplay()
        client = nil
        assetSource = nil
        store = nil
        activeID = nil
        if let next = session.activeCredentials {
            open(next)
            await reload()
            await sync()
        }
    }

    private func open(_ creds: ImmichCredentials) {
        do {
            store = try LibraryStore(path: try LibraryStore.defaultPath(for: creds.id))
            let newClient = ImmichAccountClient(credentials: creds)
            client = newClient
            assetSource = AccountAssetSource(client: newClient, store: store!)
            activeID = creds.id
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't open the local library: \(error.localizedDescription)"
        }
    }

    private func resetDisplay() {
        months = []
        albums = []
        counts = nil
        lastSummary = nil
        lastSyncText = nil
        errorMessage = nil
        dataVersion = UUID()
    }

    // MARK: Sync

    func sync() async {
        guard let store, let client, !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        let accountAtStart = client.credentials.id
        let task = Task { [weak self] in
            do {
                let engine = ImmichSyncEngine(client: client, store: store)
                let summary = try await engine.sync { [weak self] p in
                    Task { @MainActor in
                        if self?.activeID == accountAtStart { self?.progress = p }
                    }
                }
                if self?.activeID == accountAtStart { self?.lastSummary = summary }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                if self?.activeID == accountAtStart { self?.errorMessage = error.localizedDescription }
            }
        }
        syncTask = task
        await task.value
        isSyncing = false
        if activeID == accountAtStart { await reload() }
    }

    /// Cancels a sync in progress and waits for it to stop. Safe at any point: a batch is stored before it is acked.
    private func stopSync() async {
        syncTask?.cancel()
        await syncTask?.value
        syncTask = nil
        isSyncing = false
    }

    /// Throw away the active account's local copy and download everything again.
    func resetLocalData() async {
        guard let store else { return }
        try? await store.wipe()
        // The server's checkpoint is per session, so ask it to start over too.
        if let client { try? await client.ack(["SyncResetV1|reset"]) }
        await sync()
    }

    // MARK: Reading

    func reload() async {
        guard let store else { return }
        months = (try? await store.monthBuckets()) ?? []
        counts = try? await store.counts()
        albums = (try? await store.albums()) ?? []
        if let iso = try? await store.meta("lastSync"), let date = ISO8601DateFormatter().date(from: iso) {
            lastSyncText = date.formatted(.relative(presentation: .named))
        }
        dataVersion = UUID()
    }

    func assets(inMonth month: String) async -> [LibraryAsset] {
        (try? await store?.assets(inMonth: month)) ?? []
    }

    /// Everything the viewer pages through, newest first.
    func timelineAssets(favoritesOnly: Bool = false, limit: Int? = nil) async -> [Asset] {
        ((try? await store?.timelineAssets(favoritesOnly: favoritesOnly, limit: limit)) ?? []).map(\.asAsset)
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

    func albumAssets(_ albumId: String) async -> [Asset] {
        ((try? await store?.assets(inAlbum: albumId)) ?? []).map(\.asAsset)
    }

    func thumbnailURL(_ id: String) -> URL? { client?.thumbnailURL(assetId: id) }
    var imageHeaders: [String: String]? { client?.authHeaders }
    var imageCacheScope: String? { client?.cacheScope }
}
