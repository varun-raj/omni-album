//
//  ImmichAccountViewModel.swift
//  OmniAlbum
//
//  Sign-in, sync and cached timeline for an Immich account. The timeline is read from the local
//  database straight away on launch; sync then runs in the background and only brings changes.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class ImmichAccountViewModel: ObservableObject {
    @Published private(set) var credentials: ImmichCredentials?
    @Published private(set) var months: [LibraryStore.MonthBucket] = []
    @Published private(set) var counts: LibraryStore.Counts?
    @Published private(set) var lastSyncText: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var progress = SyncProgress()
    @Published private(set) var lastSummary: SyncSummary?
    @Published private(set) var isSigningIn = false
    @Published var errorMessage: String?
    /// Changes after each sync so visible month grids re-query.
    @Published private(set) var dataVersion = UUID()

    private var store: LibraryStore?
    private var client: ImmichAccountClient?

    init() {
        if let creds = ImmichAccountSession.shared.restore() {
            open(creds)
            Task {
                await reload()          // cached library first: instant
                await sync()            // then catch up
            }
        }
    }

    // MARK: Account

    func signIn(server: String, email: String, password: String) async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            let creds = try await ImmichAccountClient.signIn(server: server, email: email, password: password)
            ImmichAccountSession.shared.save(creds)
            open(creds)
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        if let creds = credentials, let path = try? LibraryStore.defaultPath(for: creds.server) {
            store = nil
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        ImmichAccountSession.shared.clear()
        credentials = nil
        client = nil
        months = []
        counts = nil
        lastSummary = nil
        lastSyncText = nil
    }

    private func open(_ creds: ImmichCredentials) {
        do {
            store = try LibraryStore(path: try LibraryStore.defaultPath(for: creds.server))
            client = ImmichAccountClient(credentials: creds)
            credentials = creds
        } catch {
            errorMessage = "Couldn't open the local library: \(error.localizedDescription)"
        }
    }

    // MARK: Sync

    func sync() async {
        guard let store, let client, !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }
        do {
            let engine = ImmichSyncEngine(client: client, store: store)
            lastSummary = try await engine.sync { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }
        } catch ImmichAccountError.unauthorized {
            errorMessage = ImmichAccountError.unauthorized.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    /// Throw away the local copy and download everything again.
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
        if let iso = try? await store.meta("lastSync"), let date = ISO8601DateFormatter().date(from: iso) {
            lastSyncText = date.formatted(.relative(presentation: .named))
        }
        dataVersion = UUID()
    }

    func assets(inMonth month: String) async -> [LibraryAsset] {
        (try? await store?.assets(inMonth: month)) ?? []
    }

    func thumbnailURL(_ id: String) -> URL? { client?.thumbnailURL(assetId: id) }
}
