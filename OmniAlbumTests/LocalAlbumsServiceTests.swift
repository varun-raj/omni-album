import XCTest
@testable import OmniAlbum

final class LocalAlbumsServiceTests: XCTestCase {
    private var file: URL!
    private var service: LocalAlbumsService!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("albums-\(UUID().uuidString).json")
        service = LocalAlbumsService(fileURL: file)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private func album(_ id: String, name: String = "A") -> DisplayAlbum {
        DisplayAlbum(id: id, albumName: name, albumThumbnailAssetId: nil, baseURL: "https://host",
                     shareKey: "key-\(id)", albumId: "album-\(id)", assetCount: 1)
    }

    func testMergeKeepsLocalOnlyAlbums() {
        service.addAlbum(album("local"))
        service.addAlbum(album("both", name: "old"))

        let merged = service.mergeWithCloudKit([album("both", name: "new"), album("cloud")])

        XCTAssertEqual(Set(merged.map(\.id)), ["local", "both", "cloud"])
        XCTAssertEqual(merged.first { $0.id == "both" }?.albumName, "new") // CloudKit wins where both exist
    }

    func testDuplicateIdsDoNotCrash() throws {
        // Two stored rows with the same id used to trap Dictionary(uniqueKeysWithValues:).
        let dup = [StoredAlbum(from: album("x")), StoredAlbum(from: album("x"))]
        try JSONEncoder().encode(dup).write(to: file)
        service.saveAlbums([album("x")])
        XCTAssertEqual(service.loadAlbums().count, 1)
    }

    func testPasswordIsNeverWrittenToDisk() throws {
        let withPassword = DisplayAlbum(id: "p", albumName: "Secret", albumThumbnailAssetId: nil, baseURL: "https://host",
                                        shareKey: "k", albumId: "a", assetCount: 1, password: "hunter2")
        service.saveAlbums([withPassword])
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains("hunter2"))
    }

    func testDeleteRemovesAlbum() {
        service.addAlbum(album("a"))
        service.addAlbum(album("b"))
        service.deleteAlbum(id: "a")
        XCTAssertEqual(service.loadAlbums().map(\.id), ["b"])
    }
}

final class UploadTaskTests: XCTestCase {
    func testPasswordNotEncoded() throws {
        let task = UploadTask(albumId: "a", albumName: "n", baseURL: "https://h", shareKey: "k", password: "pw",
                              localAssetIdentifier: "L", fileName: "f.jpg")
        let json = String(data: try JSONEncoder().encode(task), encoding: .utf8)!
        XCTAssertFalse(json.contains("pw"))
    }
}
