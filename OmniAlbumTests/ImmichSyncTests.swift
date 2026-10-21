import XCTest
@testable import OmniAlbum

// MARK: - Helpers

private func assetLine(_ id: String, date: String = "2024-05-10T10:00:00.000Z", visibility: String = "timeline", type: String = "AssetV2", ack: String? = nil, favorite: Bool = false) -> String {
    let data = #"{"id":"\#(id)","ownerId":"u1","type":"IMAGE","originalFileName":"\#(id).jpg","checksum":"c","fileCreatedAt":"\#(date)","localDateTime":"\#(date)","width":4000,"height":3000,"duration":null,"isFavorite":\#(favorite),"visibility":"\#(visibility)","thumbhash":null,"livePhotoVideoId":null,"stackId":null,"deletedAt":null,"isEdited":false,"libraryId":null,"createdAt":null}"#
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

// MARK: - Accounts

final class ImmichAccountSessionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var session: ImmichAccountSession!
    private let server = "https://acct-\(UUID().uuidString.prefix(8).lowercased()).example"

    override func setUp() {
        defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")
        session = ImmichAccountSession(defaults: defaults)
    }

    override func tearDown() {
        session.accounts.forEach { session.remove($0.id) } // clears the Keychain tokens too
    }

    private func creds(_ user: String, server: String? = nil, token: String? = nil) -> ImmichCredentials {
        ImmichCredentials(server: server ?? self.server, email: "\(user)@x", userId: user, token: token ?? "token-\(user)")
    }

    func testAddActivatesAndStoresTheToken() {
        session.add(creds("u1"))
        XCTAssertEqual(session.activeID, creds("u1").id)
        XCTAssertEqual(session.activeCredentials?.token, "token-u1")
    }

    func testTwoUsersOnOneServerKeepSeparateTokensAndLibraries() throws {
        session.add(creds("u1"))
        session.add(creds("u2"))
        XCTAssertEqual(session.accounts.count, 2)
        XCTAssertEqual(session.credentials(for: creds("u1").id)?.token, "token-u1")
        XCTAssertEqual(session.credentials(for: creds("u2").id)?.token, "token-u2")
        XCTAssertNotEqual(try LibraryStore.defaultPath(for: creds("u1").id), try LibraryStore.defaultPath(for: creds("u2").id))
    }

    func testSwitching() {
        session.add(creds("u1"))
        session.add(creds("u2"))
        XCTAssertEqual(session.activeID, creds("u2").id) // newest is active
        session.setActive(creds("u1").id)
        XCTAssertEqual(session.activeCredentials?.userId, "u1")
        session.setActive("not-an-account") // ignored
        XCTAssertEqual(session.activeCredentials?.userId, "u1")
    }

    func testRemovingTheActiveAccountFallsBackToAnother() {
        session.add(creds("u1"))
        session.add(creds("u2"))
        session.remove(creds("u2").id)
        XCTAssertEqual(session.accounts.map(\.userId), ["u1"])
        XCTAssertEqual(session.activeCredentials?.userId, "u1")
        XCTAssertNil(session.credentials(for: creds("u2").id), "token must be gone")
        session.remove(creds("u1").id)
        XCTAssertNil(session.activeID)
        XCTAssertNil(session.activeCredentials)
    }

    func testSigningInAgainReplacesTheTokenWithoutDuplicating() {
        session.add(creds("u1", token: "old"))
        session.add(creds("u1", token: "new"))
        XCTAssertEqual(session.accounts.count, 1)
        XCTAssertEqual(session.activeCredentials?.token, "new")
    }

    func testSurvivesRelaunch() {
        session.add(creds("u1"))
        let relaunched = ImmichAccountSession(defaults: defaults)
        XCTAssertEqual(relaunched.activeCredentials?.userId, "u1")
    }
}


// MARK: - Viewer feed

final class AccountViewerFeedTests: XCTestCase {
    private func change(_ json: String) throws -> LibraryChange {
        let data = Data(json.utf8), d = JSONDecoder()
        guard case .change(let c) = try SyncLine.decode(data, header: try d.decode(SyncLineHeader.self, from: data), decoder: d) else { throw XCTSkip() }
        return c
    }

    func testTimelineIsNewestFirstAndFavouritesFilter() async throws {
        let (store, _) = try tempStore()
        try await store.apply([
            try change(assetLine("old", date: "2020-01-01T00:00:00.000Z")),
            try change(assetLine("fav", date: "2023-01-01T00:00:00.000Z", favorite: true)),
            try change(assetLine("new", date: "2024-01-01T00:00:00.000Z")),
            try change(assetLine("hidden", date: "2025-01-01T00:00:00.000Z", visibility: "archive")),
        ])
        let all = try await store.timelineAssets()
        XCTAssertEqual(all.map(\.id), ["new", "fav", "old"])
        let favourites = try await store.timelineAssets(favoritesOnly: true)
        XCTAssertEqual(favourites.map(\.id), ["fav"])
    }

    func testExifRoundTrip() async throws {
        let (store, _) = try tempStore()
        let exif = try change(line("AssetExifV1", #"{"assetId":"a","city":"Paris","state":null,"country":"France","make":"Apple","model":"iPhone","lensModel":null,"latitude":48.85,"longitude":2.35,"description":null,"fileSizeInByte":123456,"iso":100,"fNumber":1.8,"focalLength":26.0,"exposureTime":"1/120","rating":null,"orientation":"1","dateTimeOriginal":null,"exifImageWidth":4000,"exifImageHeight":3000}"#, ack: "AssetExifV1|a"))
        try await store.apply([exif])
        let loaded = try await store.exif(assetId: "a")
        XCTAssertEqual(loaded?.city, "Paris")
        XCTAssertEqual(loaded?.iso, 100)
        XCTAssertEqual(loaded?.latitude ?? 0, 48.85, accuracy: 0.001)
        let missing = try await store.exif(assetId: "nope")
        XCTAssertNil(missing)
    }

    func testDurationIsConvertedFromMilliseconds() {
        let video = LibraryAsset(id: "v", type: "VIDEO", fileName: "v.mov", localDateTime: "2024-01-01T00:00:00.000Z",
                                 width: 1920, height: 1080, duration: 3_725_000, isFavorite: false, thumbhash: nil)
        XCTAssertEqual(video.asAsset.duration, "1:02:05")
        XCTAssertEqual(video.asAsset.type, .video)
        let photo = LibraryAsset(id: "p", type: "IMAGE", fileName: "p.jpg", localDateTime: "2024-01-01T00:00:00.000Z",
                                 width: 10, height: 10, duration: nil, isFavorite: false, thumbhash: nil)
        XCTAssertNil(photo.asAsset.duration)
        XCTAssertEqual(photo.asAsset.type, .image)
    }
}

// MARK: - Hub (home Albums list)

@MainActor
final class ImmichHubTests: XCTestCase {
    private func library(_ user: String, albumNames: [(id: String, name: String, updated: String)]) async throws -> AccountLibrary {
        let (store, _) = try tempStore()
        let changes: [LibraryChange] = albumNames.map { a in
            .album(try! JSONDecoder().decode(SyncAlbum.self, from: Data(
                #"{"id":"\#(a.id)","name":"\#(a.name)","description":"","thumbnailAssetId":null,"createdAt":"2024-01-01","updatedAt":"\#(a.updated)","order":"desc"}"#.utf8)))
        }
        try await store.apply(changes)
        let creds = ImmichCredentials(server: "https://\(user).test", email: "\(user)@x", userId: user, token: "t")
        return AccountLibrary(info: creds.info, client: ImmichAccountClient(credentials: creds), store: store)
    }

    func testAlbumsFromAllAccountsAreMergedNewestFirst() async throws {
        let hub = ImmichHub(session: ImmichAccountSession(defaults: UserDefaults(suiteName: "hub-\(UUID())")!))
        hub.attach(try await library("alice", albumNames: [("a1", "Trip", "2024-03-01"), ("a2", "Old", "2020-01-01")]))
        hub.attach(try await library("bob", albumNames: [("a1", "Same id, other account", "2025-01-01")]))
        await hub.reloadAlbums()

        XCTAssertEqual(hub.albums.map(\.album.name), ["Same id, other account", "Trip", "Old"])
        XCTAssertEqual(Set(hub.albums.map(\.id)).count, 3, "an album id reused by two accounts must stay distinct")
        XCTAssertEqual(hub.albums.first?.account.userId, "bob")
    }

    func testRemovingAnAccountDropsItsAlbums() async throws {
        let hub = ImmichHub(session: ImmichAccountSession(defaults: UserDefaults(suiteName: "hub-\(UUID())")!))
        let alice = try await library("alice", albumNames: [("a1", "Trip", "2024-03-01")])
        hub.attach(alice)
        hub.attach(try await library("bob", albumNames: [("b1", "Beach", "2024-04-01")]))
        await hub.reloadAlbums()
        XCTAssertEqual(hub.albums.count, 2)

        await hub.remove(alice.info.id)
        XCTAssertEqual(hub.albums.map(\.album.name), ["Beach"])
        XCTAssertNil(hub.library(for: alice.info.id))
    }

    func testAlbumAssetsComeFromTheRightAccount() async throws {
        let hub = ImmichHub(session: ImmichAccountSession(defaults: UserDefaults(suiteName: "hub-\(UUID())")!))
        let alice = try await library("alice", albumNames: [("a1", "Trip", "2024-03-01")])
        let line = assetLine("p1")
        let data = Data(line.utf8), d = JSONDecoder()
        guard case .change(let asset) = try SyncLine.decode(data, header: try d.decode(SyncLineHeader.self, from: data), decoder: d) else { return XCTFail() }
        try await alice.store.apply([asset, .albumAsset(albumId: "a1", assetId: "p1")])
        hub.attach(alice)
        hub.attach(try await library("bob", albumNames: [("a1", "Empty", "2024-04-01")]))
        await hub.reloadAlbums()

        let aliceAlbum = hub.albums.first { $0.account.userId == "alice" }!
        let bobAlbum = hub.albums.first { $0.account.userId == "bob" }!
        let aliceAssets = await hub.albumAssets(aliceAlbum)
        let bobAssets = await hub.albumAssets(bobAlbum)
        XCTAssertEqual(aliceAssets.map(\.id), ["p1"])
        XCTAssertTrue(bobAssets.isEmpty)
    }
}

// MARK: - Account uploads (request shape; no photo library or server needed)

final class ImmichAccountUploadTests: XCTestCase {
    private let service = ImmichUploadService()

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    func testUploadURLShareLinkUsesKeyAccountUsesNone() {
        let link = service.buildUploadURL(baseURL: "https://h.test/immich", auth: .shareLink(key: "K", password: "pw"))
        XCTAssertEqual(link.absoluteString, "https://h.test/immich/api/assets?key=K&password=pw")
        let account = service.buildUploadURL(baseURL: "https://h.test/immich", auth: .bearer(token: "T"))
        XCTAssertEqual(account.absoluteString, "https://h.test/immich/api/assets", "tokens go in a header, never the URL")
    }

    func testBearerHeaderOnlyForAccounts() {
        var account = URLRequest(url: URL(string: "https://h.test/api/assets")!)
        service.apply(.bearer(token: "T"), to: &account)
        XCTAssertEqual(account.value(forHTTPHeaderField: "Authorization"), "Bearer T")
        var link = URLRequest(url: URL(string: "https://h.test/api/assets")!)
        service.apply(.shareLink(key: "K", password: nil), to: &link)
        XCTAssertNil(link.value(forHTTPHeaderField: "Authorization"))
    }

    func testSHA1IsBase64OfTheFileBytes() throws {
        let file = try tempFile(Array("abc".utf8))
        XCTAssertEqual(try service.sha1Base64(of: file), "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=") // SHA-1("abc"), as Immich stores it
    }

    func testMultipartBodyHasTheFieldsImmichNeedsAndTheExactBytes() throws {
        let payload: [UInt8] = (0..<5000).map { UInt8($0 % 251) }
        let file = try tempFile(payload)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let body = try service.buildMultipartFile(
            boundary: "BOUND", assetFile: file, fileName: "IMG_1.mov", mimeType: "video/quicktime",
            metadata: UploadMetadata(createdAt: when, isFavorite: true, isVideo: true, durationSeconds: 12.5),
            deviceAssetId: "local-id", durationInMilliseconds: true)
        let data = try Data(contentsOf: body)
        let text = String(decoding: data, as: UTF8.self)

        for field in ["deviceAssetId", "deviceId", "fileCreatedAt", "fileModifiedAt", "isFavorite", "duration", "assetData"] {
            XCTAssertTrue(text.contains("name=\"\(field)\""), "missing \(field)")
        }
        XCTAssertTrue(text.contains("filename=\"IMG_1.mov\""))
        XCTAssertTrue(text.contains("Content-Type: video/quicktime"))
        XCTAssertTrue(text.contains("\r\n12500\r\n"), "Immich 3 wants whole milliseconds")
        XCTAssertTrue(text.contains("\r\ntrue\r\n"))
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
        XCTAssertNotNil(data.range(of: Data(payload)), "the file must be copied through unchanged")
    }

    func testPhotosCarryNoDuration() throws {
        let body = try service.buildMultipartFile(
            boundary: "B", assetFile: try tempFile([1, 2, 3]), fileName: "a.jpg", mimeType: "image/jpeg",
            metadata: UploadMetadata(createdAt: Date()), deviceAssetId: "x", durationInMilliseconds: true)
        XCTAssertFalse(String(decoding: try Data(contentsOf: body), as: UTF8.self).contains("name=\"duration\""))
    }

    func testAddToAlbumSendsBearerAndIds() async throws {
        StubServer.requests = []
        nonisolated(unsafe) var seen: (method: String?, auth: String?, path: String?)?
        StubServer.handler = { req in
            seen = (req.httpMethod, req.value(forHTTPHeaderField: "Authorization"), req.url?.path)
            return (200, "[]")
        }
        let uploader = ImmichUploadService(protocolClasses: [StubServer.self])
        try await uploader.addAssetToAlbum(assetId: "asset-1", albumId: "al-9", baseURL: "https://h.test/immich", auth: .bearer(token: "T"))

        XCTAssertEqual(seen?.method, "PUT")
        XCTAssertEqual(seen?.auth, "Bearer T")
        XCTAssertEqual(seen?.path, "/immich/api/albums/al-9/assets")
        XCTAssertTrue(StubServer.requests.last?.body.contains("asset-1") == true)
    }

    // MARK: Destinations and persistence

    func testImmichDestinationTargetsTheAccountAndAlbum() {
        let account = ImmichAccountInfo(server: "https://h.test", email: "me@x", userId: "u1")
        let picked = SelectedAsset(localIdentifier: "L1", fileName: "IMG.jpg", fileSize: 10, thumbnail: nil)

        let toAlbum = UploadDestination.immich(account: account, albumId: "al1", albumName: "Trip").makeTask(picked)
        XCTAssertEqual(toAlbum.accountID, account.id)
        XCTAssertEqual(toAlbum.targetAlbumId, "al1")
        XCTAssertEqual(toAlbum.albumId, "al1") // queue UI groups by album
        XCTAssertEqual(toAlbum.baseURL, "https://h.test")
        XCTAssertEqual(toAlbum.shareKey, "")

        let toLibrary = UploadDestination.immich(account: account).makeTask(picked)
        XCTAssertNil(toLibrary.targetAlbumId)
        XCTAssertEqual(toLibrary.albumName, "Immich library")
        XCTAssertEqual(toLibrary.albumId, "library|\(account.id)")
    }

    func testTaskRoundTripsAndOldQueueFilesStillLoad() throws {
        let task = UploadTask(albumId: "a", albumName: "n", baseURL: "https://h", shareKey: "", localAssetIdentifier: "L", fileName: "f.jpg",
                              accountID: "https://h|u1", targetAlbumId: "al1")
        let back = try JSONDecoder().decode(UploadTask.self, from: try JSONEncoder().encode(task))
        XCTAssertEqual(back.accountID, "https://h|u1")
        XCTAssertEqual(back.targetAlbumId, "al1")

        // A queue file written before accounts existed has neither field.
        var legacy = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(task)) as! [String: Any]
        legacy["accountID"] = nil
        legacy["targetAlbumId"] = nil
        let old = try JSONDecoder().decode(UploadTask.self, from: try JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.accountID)
        XCTAssertNil(old.targetAlbumId)
    }
}

// MARK: - Upload tab targets

final class UploadTargetTests: XCTestCase {
    private func account(_ user: String) -> ImmichAccountInfo { ImmichAccountInfo(server: "https://\(user).test", email: "\(user)@x", userId: user) }

    private func album(_ account: ImmichAccountInfo, _ id: String, _ name: String, items: Int = 3) -> AccountAlbum {
        AccountAlbum(account: account, album: LibraryAlbum(id: id, name: name, description: "", thumbnailAssetId: nil, updatedAt: "2024", assetCount: items))
    }

    private func link(_ id: String, _ name: String, upload: Bool) -> DisplayAlbum {
        DisplayAlbum(id: id, albumName: name, albumThumbnailAssetId: nil, baseURL: "https://share.test", shareKey: "k", albumId: id, assetCount: 1, allowUpload: upload)
    }

    func testEachAccountGetsLibraryThenItsAlbumsSortedByName() {
        let a = account("alice"), b = account("bob")
        let targets = UploadTarget.build(accounts: [a, b],
                                         albums: [album(a, "2", "Zoo"), album(b, "9", "Bob's"), album(a, "1", "Apples")],
                                         shareLinkAlbums: [])
        XCTAssertEqual(targets.map(\.title), ["Library", "Apples", "Zoo", "Library", "Bob's"])
        XCTAssertEqual(targets.map(\.kind), [.immichLibrary, .immichAlbum, .immichAlbum, .immichLibrary, .immichAlbum])
        XCTAssertEqual(Set(targets.map(\.id)).count, targets.count)
    }

    func testOnlyUploadableSharedLinksAreOffered() {
        let targets = UploadTarget.build(accounts: [], albums: [], shareLinkAlbums: [link("1", "Open", upload: true), link("2", "ReadOnly", upload: false)])
        XCTAssertEqual(targets.map(\.title), ["Open"])
        XCTAssertEqual(targets.first?.group, "Shared links")
    }

    func testTargetsProduceTasksForTheirDestination() {
        let a = account("alice")
        let targets = UploadTarget.build(accounts: [a], albums: [album(a, "al1", "Trip")], shareLinkAlbums: [link("L", "Link", upload: true)])
        let picked = SelectedAsset(localIdentifier: "x", fileName: "f.jpg", fileSize: 1, thumbnail: nil)
        let tasks = targets.map { $0.destination.makeTask(picked) }
        XCTAssertEqual(tasks[0].accountID, a.id); XCTAssertNil(tasks[0].targetAlbumId)       // library
        XCTAssertEqual(tasks[1].targetAlbumId, "al1")                                        // album
        XCTAssertNil(tasks[2].accountID); XCTAssertEqual(tasks[2].shareKey, "k")             // shared link keeps its key
    }

    func testNothingToUploadToWhenSignedOutAndNoLinks() {
        XCTAssertTrue(UploadTarget.build(accounts: [], albums: [], shareLinkAlbums: []).isEmpty)
    }
}
