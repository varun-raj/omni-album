import XCTest
@testable import OmniAlbum

// MARK: - Helpers

private func assetLine(_ id: String, date: String = "2024-05-10T10:00:00.000Z", visibility: String = "timeline", type: String = "AssetV2", ack: String? = nil) -> String {
    let data = #"{"id":"\#(id)","ownerId":"u1","type":"IMAGE","originalFileName":"\#(id).jpg","checksum":"c","fileCreatedAt":"\#(date)","localDateTime":"\#(date)","width":4000,"height":3000,"duration":null,"isFavorite":false,"visibility":"\#(visibility)","thumbhash":null,"livePhotoVideoId":null,"stackId":null,"deletedAt":null,"isEdited":false,"libraryId":null,"createdAt":null}"#
    return #"{"type":"\#(type)","data":\#(data),"ack":"\#(ack ?? "\(type)|\(id)")"}"#
}

private func line(_ type: String, _ data: String, ack: String) -> String {
    #"{"type":"\#(type)","data":\#(data),"ack":"\#(ack)"}"#
}

private func tempStore() throws -> (LibraryStore, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString).sqlite")
    return (try LibraryStore(path: url.path), url)
}

// MARK: - Decoding

final class SyncLineTests: XCTestCase {
    private func decode(_ json: String) throws -> SyncLine {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        return try SyncLine.decode(data, header: try decoder.decode(SyncLineHeader.self, from: data), decoder: decoder)
    }

    func testAssetAndDelete() throws {
        guard case .change(.asset(let a)) = try decode(assetLine("a1")) else { return XCTFail() }
        XCTAssertEqual(a.id, "a1")
        XCTAssertEqual(a.visibility, "timeline")
        guard case .change(.assetDeleted(let id)) = try decode(line("AssetDeleteV1", #"{"assetId":"a1"}"#, ack: "x")) else { return XCTFail() }
        XCTAssertEqual(id, "a1")
    }

    func testAlbumAssetsBecomeAssets() throws {
        guard case .change(.asset) = try decode(assetLine("a2", type: "AlbumAssetBackfillV2")) else { return XCTFail() }
    }

    func testControlLinesAndUnknownTypes() throws {
        guard case .complete = try decode(line("SyncCompleteV1", "{}", ack: "SyncCompleteV1|1")) else { return XCTFail() }
        guard case .reset = try decode(line("SyncResetV1", "{}", ack: "SyncResetV1|reset")) else { return XCTFail() }
        guard case .ignored = try decode(line("SomethingNewV9", #"{"x":1}"#, ack: "a|b")) else { return XCTFail() }
    }
}

// MARK: - Store

final class LibraryStoreTests: XCTestCase {
    private func asset(_ id: String, date: String, visibility: String = "timeline") throws -> LibraryChange {
        guard case .change(let c) = try {
            let json = assetLine(id, date: date, visibility: visibility)
            let data = Data(json.utf8), d = JSONDecoder()
            return try SyncLine.decode(data, header: try d.decode(SyncLineHeader.self, from: data), decoder: d)
        }() else { throw XCTSkip() }
        return c
    }

    func testMonthBucketsGroupAndSkipHiddenAndDeleted() async throws {
        let (store, _) = try tempStore()
        try await store.apply([
            try asset("a", date: "2024-05-10T10:00:00.000Z"),
            try asset("b", date: "2024-05-02T10:00:00.000Z"),
            try asset("c", date: "2023-12-31T23:00:00.000Z"),
            try asset("hidden", date: "2024-05-03T10:00:00.000Z", visibility: "archive"),
        ])
        try await store.apply([.assetDeleted(id: "b")])
        let buckets = try await store.monthBuckets()
        XCTAssertEqual(buckets.map(\.month), ["2024-05", "2023-12"]) // newest first
        XCTAssertEqual(buckets.map(\.count), [1, 1])
    }

    func testUpsertIsIdempotent() async throws {
        let (store, _) = try tempStore()
        let change = try asset("a", date: "2024-05-10T10:00:00.000Z")
        try await store.apply([change, change])
        try await store.apply([change])
        let counts = try await store.counts()
        XCTAssertEqual(counts.assets, 1)
    }

    func testAlbumMembership() async throws {
        let (store, _) = try tempStore()
        let album = LibraryChange.album(try JSONDecoder().decode(SyncAlbum.self, from:
            Data(#"{"id":"al","name":"Trip","description":"","thumbnailAssetId":null,"createdAt":"2024-01-01","updatedAt":"2024-01-02","order":"desc"}"#.utf8)))
        try await store.apply([try asset("a", date: "2024-05-10T10:00:00.000Z"), try asset("b", date: "2024-05-11T10:00:00.000Z"),
                               album, .albumAsset(albumId: "al", assetId: "a"), .albumAsset(albumId: "al", assetId: "b")])
        var albums = try await store.albums()
        XCTAssertEqual(albums.first?.assetCount, 2)
        try await store.apply([.albumAssetDeleted(albumId: "al", assetId: "a")])
        albums = try await store.albums()
        XCTAssertEqual(albums.first?.assetCount, 1)
        let inAlbum = try await store.assets(inAlbum: "al")
        XCTAssertEqual(inAlbum.map(\.id), ["b"])
        try await store.apply([.albumDeleted(id: "al")])
        let remaining = try await store.albums()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDeletingAnAssetRemovesItFromAlbums() async throws {
        let (store, _) = try tempStore()
        try await store.apply([try asset("a", date: "2024-05-10T10:00:00.000Z"), .albumAsset(albumId: "al", assetId: "a")])
        try await store.apply([.assetDeleted(id: "a")])
        let inAlbum = try await store.assets(inAlbum: "al")
        XCTAssertTrue(inAlbum.isEmpty)
    }

    func testWipe() async throws {
        let (store, _) = try tempStore()
        try await store.apply([try asset("a", date: "2024-05-10T10:00:00.000Z")])
        try await store.wipe()
        let counts = try await store.counts()
        XCTAssertEqual(counts.assets, 0)
    }
}

// MARK: - Engine (against a stubbed server)

private final class StubServer: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var requests: [(path: String, body: String)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = ""
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body += String(decoding: buffer[0..<n], as: UTF8.self)
            }
            stream.close()
        } else if let data = request.httpBody {
            body = String(decoding: data, as: UTF8.self)
        }
        Self.requests.append((request.url?.path ?? "", body))
        let (status, text) = Self.handler?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ImmichSyncEngineTests: XCTestCase {
    private func makeEngine(store: LibraryStore) -> ImmichSyncEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        let creds = ImmichCredentials(server: "https://immich.test", email: "me@x", userId: "u1", token: "tok")
        return ImmichSyncEngine(client: ImmichAccountClient(credentials: creds, session: URLSession(configuration: config)), store: store)
    }

    override func setUp() { StubServer.requests = []; StubServer.handler = nil }

    func testFirstSyncStoresEverythingThenAcksLatestPerType() async throws {
        let (store, _) = try tempStore()
        let lines = (1...2500).map { assetLine("a\($0)") }.joined(separator: "\n")
            + "\n" + line("SyncCompleteV1", "{}", ack: "SyncCompleteV1|9")
        StubServer.handler = { req in
            req.url!.path == "/api/sync/stream" ? (200, lines) : (204, "")
        }

        let summary = try await makeEngine(store: store).sync()

        let counts = try await store.counts()
        XCTAssertEqual(counts.assets, 2500)
        XCTAssertEqual(summary.applied, 2500)
        XCTAssertFalse(summary.didFullReset)

        let acks = StubServer.requests.filter { $0.path == "/api/sync/ack" }
        XCTAssertEqual(acks.count, 3) // 1000 + 1000 + (500 + complete): batched, not one per line
        XCTAssertTrue(acks.last!.body.contains("AssetV2|a2500"), acks.last!.body) // newest ack of the type
        XCTAssertFalse(acks.last!.body.contains("AssetV2|a1\""))
    }

    func testSecondSyncWithNoChangesDownloadsNothing() async throws {
        let (store, _) = try tempStore()
        StubServer.handler = { req in
            guard req.url!.path == "/api/sync/stream" else { return (204, "") }
            return (200, assetLine("a1") + "\n" + line("SyncCompleteV1", "{}", ack: "SyncCompleteV1|1"))
        }
        let engine = makeEngine(store: store)
        _ = try await engine.sync()
        StubServer.handler = { req in
            req.url!.path == "/api/sync/stream" ? (200, line("SyncCompleteV1", "{}", ack: "SyncCompleteV1|2")) : (204, "")
        }
        let second = try await engine.sync()
        XCTAssertEqual(second.applied, 0)
        let counts = try await store.counts()
        XCTAssertEqual(counts.assets, 1)
    }

    func testResetWipesAcksTheResetAndStreamsAgain() async throws {
        let (store, _) = try tempStore()
        try await store.apply([.assetDeleted(id: "x")]) // no-op, just proves the store works
        nonisolated(unsafe) var streamCalls = 0
        StubServer.handler = { req in
            guard req.url!.path == "/api/sync/stream" else { return (204, "") }
            streamCalls += 1
            return streamCalls == 1
                ? (200, line("SyncResetV1", "{}", ack: "SyncResetV1|reset"))
                : (200, assetLine("fresh") + "\n" + line("SyncCompleteV1", "{}", ack: "SyncCompleteV1|1"))
        }
        let summary = try await makeEngine(store: store).sync()
        XCTAssertTrue(summary.didFullReset)
        XCTAssertEqual(streamCalls, 2)
        XCTAssertTrue(StubServer.requests.contains { $0.path == "/api/sync/ack" && $0.body.contains("SyncResetV1|reset") })
        let counts = try await store.counts()
        XCTAssertEqual(counts.assets, 1)
    }

    func testUnauthorizedIsReported() async throws {
        let (store, _) = try tempStore()
        StubServer.handler = { _ in (401, "{}") }
        do {
            _ = try await makeEngine(store: store).sync()
            XCTFail("should throw")
        } catch ImmichAccountError.unauthorized {
        }
    }

    func testBearerTokenIsSent() async throws {
        let (store, _) = try tempStore()
        nonisolated(unsafe) var auth: String?
        StubServer.handler = { req in
            auth = req.value(forHTTPHeaderField: "Authorization")
            return (200, line("SyncCompleteV1", "{}", ack: "SyncCompleteV1|1"))
        }
        _ = try await makeEngine(store: store).sync()
        XCTAssertEqual(auth, "Bearer tok")
    }
}
