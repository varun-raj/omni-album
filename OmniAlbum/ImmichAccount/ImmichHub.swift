//
//  ImmichHub.swift
//  OmniAlbum
//
//  Every signed-in Immich account's local library, kept in sync in the background. The home Albums
//  list and the account screen both read from here, so albums from all accounts show up next to
//  shared-link albums without visiting the account screen first.
//

import Combine
import Foundation

/// One signed-in account's opened library.
final class AccountLibrary {
    let info: ImmichAccountInfo
    let client: ImmichAccountClient
    let store: LibraryStore
    let source: AccountAssetSource

    @MainActor
    init(info: ImmichAccountInfo, client: ImmichAccountClient, store: LibraryStore) {
        self.info = info
        self.client = client
        self.store = store
        self.source = AccountAssetSource(client: client, store: store)
    }
}

/// An Immich album, tagged with the account it belongs to.
struct AccountAlbum: Identifiable, Hashable, Sendable {
    let account: ImmichAccountInfo
    let album: LibraryAlbum
    var id: String { "\(account.id)|\(album.id)" }
}

@MainActor
final class ImmichHub: ObservableObject {
    static let shared = ImmichHub()

    struct SyncStatus {
        var isSyncing = false
        var progress = SyncProgress()
        var summary: SyncSummary?
        var error: String?
    }

    /// Signed-in accounts, in sign-in order.
    @Published private(set) var accounts: [ImmichAccountInfo] = []
    /// Albums of every account, most recently changed first.
    @Published private(set) var albums: [AccountAlbum] = []
    @Published private(set) var status: [String: SyncStatus] = [:]
    /// Changes after any sync, so views reading a library re-query.
    @Published private(set) var dataVersion = UUID()

    private(set) var libraries: [String: AccountLibrary] = [:]
    private let session: ImmichAccountSession
    private var syncTasks: [String: Task<Void, Never>] = [:]

    init(session: ImmichAccountSession = .shared) {
        self.session = session
        accounts = session.accounts
    }

    var isSyncingAny: Bool { status.values.contains { $0.isSyncing } }
    func library(for id: String) -> AccountLibrary? { libraries[id] }

    // MARK: Lifecycle

    private var started = false

    /// Called once at launch, and by anything that needs the libraries open. Idempotent.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        start()
    }

    /// Opens every signed-in account's cached library (albums appear at once), then catches each one up.
    func start() {
        for info in session.accounts { _ = openLibrary(for: info.id) }
        Task {
            await reloadAlbums()
            for id in session.accounts.map(\.id) { await sync(id) }
        }
    }

    /// A freshly signed-in account.
    @discardableResult
    func add(_ creds: ImmichCredentials) -> AccountLibrary? {
        session.add(creds)
        accounts = session.accounts
        return openLibrary(for: creds.id)
    }

    /// Signs in to a server (adding the account, or refreshing its session) and starts its first sync.
    @discardableResult
    func signIn(server: String, email: String, password: String) async throws -> ImmichAccountInfo {
        let creds = try await ImmichAccountClient.signIn(server: server, email: email, password: password)
        add(creds)
        Task { await sync(creds.id) }
        return creds.info
    }

    func attach(_ library: AccountLibrary) {
        libraries[library.info.id] = library
    }

    /// Signs out one account and deletes its local copy.
    func remove(_ id: String) async {
        await cancelSync(id)
        libraries[id] = nil
        status[id] = nil
        if let path = try? LibraryStore.defaultPath(for: id) {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        session.remove(id)
        accounts = session.accounts
        await reloadAlbums()
        dataVersion = UUID()
    }

    @discardableResult
    private func openLibrary(for id: String) -> AccountLibrary? {
        if let existing = libraries[id] { return existing }
        guard let creds = session.credentials(for: id),
              let path = try? LibraryStore.defaultPath(for: id),
              let store = try? LibraryStore(path: path) else { return nil }
        let library = AccountLibrary(info: creds.info, client: ImmichAccountClient(credentials: creds), store: store)
        attach(library)
        return library
    }

    // MARK: Sync

    func sync(_ id: String) async {
        guard let library = libraries[id], status[id]?.isSyncing != true else { return }
        status[id] = SyncStatus(isSyncing: true)

        // Albums can arrive early in a long first sync: refresh the lists now and then so they appear as they land.
        let refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.reloadAlbums()
            }
        }
        let task = Task { [weak self] in
            do {
                let engine = ImmichSyncEngine(client: library.client, store: library.store)
                let summary = try await engine.sync { p in
                    Task { @MainActor [weak self] in self?.status[id]?.progress = p }
                }
                self?.status[id]?.summary = summary
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self?.status[id]?.error = error.localizedDescription
            }
        }
        syncTasks[id] = task
        await task.value
        refresher.cancel()
        syncTasks[id] = nil
        status[id]?.isSyncing = false
        await reloadAlbums()
        dataVersion = UUID()
    }

    /// Stops a sync and waits for it. Safe at any point: a batch is stored before it is acked.
    func cancelSync(_ id: String) async {
        syncTasks[id]?.cancel()
        await syncTasks[id]?.value
        syncTasks[id] = nil
        status[id]?.isSyncing = false
    }

    // MARK: Reading

    func reloadAlbums() async {
        var all: [AccountAlbum] = []
        for library in libraries.values {
            let list = (try? await library.store.albums()) ?? []
            all += list.map { AccountAlbum(account: library.info, album: $0) }
        }
        all.sort { $0.album.updatedAt > $1.album.updatedAt }
        if all != albums { albums = all }
    }

    func albumAssets(_ album: AccountAlbum) async -> [Asset] {
        guard let library = libraries[album.account.id] else { return [] }
        return ((try? await library.store.assets(inAlbum: album.album.id)) ?? []).map(\.asAsset)
    }
}
