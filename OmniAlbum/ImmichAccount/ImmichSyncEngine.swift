//
//  ImmichSyncEngine.swift
//  OmniAlbum
//
//  Keeps LibraryStore in step with the server using Immich's sync stream, so only changes are
//  downloaded after the first run.
//
//  Protocol (server/src/services/sync.service.ts):
//   - POST /api/sync/stream {types:[...]} returns JSON lines {type, data, ack}. The server keeps a checkpoint
//     per login session and resumes after the last ack it was given; it ends the stream with SyncCompleteV1.
//   - We store a batch FIRST, and only then POST /api/sync/ack with the latest ack per type. A crash between
//     the two re-sends the batch (harmless: every apply is an upsert or delete), never loses one.
//   - SyncResetV1 means "your copy is invalid": wipe, ack the reset, and stream again from scratch.
//

import Foundation
import os

struct SyncProgress: Sendable {
    var linesRead = 0
    var applied = 0
    var phase = "Connecting…"
}

struct SyncSummary: Sendable {
    let linesRead: Int
    let applied: Int
    let duration: TimeInterval
    let didFullReset: Bool
}

actor ImmichSyncEngine {
    /// What we mirror: own assets + EXIF, albums and their membership, and the assets/EXIF of shared albums.
    static let requestTypes = ["AssetsV2", "AssetExifsV1", "AlbumsV2", "AlbumToAssetsV1", "AlbumAssetsV2", "AlbumAssetExifsV1"]
    static let batchSize = 1000

    private let client: ImmichAccountClient
    private let store: LibraryStore
    private let log = Logger(subsystem: "com.skcript.omnialbum", category: "immich-sync")
    private let decoder = JSONDecoder()

    init(client: ImmichAccountClient, store: LibraryStore) {
        self.client = client
        self.store = store
    }

    func sync(onProgress: @escaping @Sendable (SyncProgress) -> Void = { _ in }) async throws -> SyncSummary {
        let started = Date()
        var progress = SyncProgress()
        var didReset = false

        // A reset restarts the stream once from empty; more than two in a row means something is wrong server-side.
        for _ in 0..<3 {
            switch try await runStream(progress: &progress, onProgress: onProgress) {
            case .complete:
                try await store.setMeta("lastSync", ISO8601DateFormatter().string(from: Date()))
                log.notice("sync done: \(progress.linesRead) lines, \(progress.applied) applied")
                return SyncSummary(linesRead: progress.linesRead, applied: progress.applied,
                                   duration: Date().timeIntervalSince(started), didFullReset: didReset)
            case .reset(let ack):
                log.notice("server requested a full resync")
                didReset = true
                try await store.wipe()
                try await client.ack([ack])
                progress.phase = "Resyncing…"
                onProgress(progress)
            }
        }
        throw ImmichAccountError.server(status: 0, body: "The server kept asking for a full resync.")
    }

    private enum Outcome {
        case complete
        case reset(ack: String)
    }

    private func runStream(progress: inout SyncProgress, onProgress: @escaping @Sendable (SyncProgress) -> Void) async throws -> Outcome {
        let request = try client.request("/api/sync/stream", method: "POST", json: ["types": Self.requestTypes])
        let (bytes, response) = try await client.session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 300 { break } }
            if http.statusCode == 401 { throw ImmichAccountError.unauthorized }
            throw ImmichAccountError.server(status: http.statusCode, body: body)
        }

        var batch: [LibraryChange] = []
        var latestAck: [String: String] = [:] // entity type -> newest ack

        func flush() async throws {
            if !batch.isEmpty {
                try await store.apply(batch)
                progress.applied += batch.count
                batch.removeAll(keepingCapacity: true)
            }
            // Acks go out only after the batch is on disk.
            try await client.ack(Array(latestAck.values))
            latestAck.removeAll()
            onProgress(progress)
        }

        progress.phase = "Syncing…"
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            let header = try decoder.decode(SyncLineHeader.self, from: data)
            progress.linesRead += 1

            switch try SyncLine.decode(data, header: header, decoder: decoder) {
            case .reset:
                return .reset(ack: header.ack)
            case .complete:
                try await flush()
                return .complete
            case .change(let change):
                batch.append(change)
            case .ignored:
                break
            }
            latestAck[String(header.ack.split(separator: "|", maxSplits: 1).first ?? "")] = header.ack

            if batch.count >= Self.batchSize { try await flush() }
            if progress.linesRead % 250 == 0 { onProgress(progress) }
        }
        // Stream ended without SyncCompleteV1 (dropped connection): keep what arrived, report it as not complete.
        try await flush()
        throw ImmichAccountError.server(status: 0, body: "The connection closed before the sync finished.")
    }
}
