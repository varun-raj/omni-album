import XCTest
@testable import OmniAlbum

final class AlbumCSVTests: XCTestCase {
    private func album(name: String, key: String = "k1", provider: PhotoProvider = .immich) -> DisplayAlbum {
        DisplayAlbum(id: "link-\(key)", albumName: name, albumThumbnailAssetId: nil, baseURL: "https://host",
                     shareKey: key, albumId: "a-\(key)", assetCount: 3, provider: provider)
    }

    func testParseLineHandlesQuotedCommasAndEscapedQuotes() {
        XCTAssertEqual(AlbumCSV.parseLine(#""a, b","say ""hi""",3"#), ["a, b", #"say "hi""#, "3"])
        XCTAssertEqual(AlbumCSV.parseLine("x,,y"), ["x", "", "y"])
    }

    func testExportThenParseRoundTrips() {
        let albums = [album(name: #"Trip, "2024""#, key: "one"), album(name: "Beach", key: "two")]
        let parsed = AlbumCSV.parseShareLinks(AlbumCSV.export(albums))
        XCTAssertEqual(parsed.map(\.link), ["https://host/share/one", "https://host/share/two"])
        XCTAssertEqual(parsed.map(\.provider), [.immich, .immich])
    }

    func testLegacyFormatRebuildsLinks() {
        let csv = """
        albumName,baseURL,shareKey,albumId,assetCount,allowUpload,allowDownload,provider
        "Old","https://host","tok","a1",5,false,true,lychee
        """
        let parsed = AlbumCSV.parseShareLinks(csv)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].link, "https://host/gallery/tok")
        XCTAssertEqual(parsed[0].provider, .lychee)
    }

    func testSkipsRowsWithoutALink() {
        let csv = "albumName,shareLink\n\"A\",\"\"\n\"B\",\"https://host/share/x\"\n"
        XCTAssertEqual(AlbumCSV.parseShareLinks(csv).count, 1)
    }
}

final class ShareLinkBuilderTests: XCTestCase {
    func testPerProvider() {
        XCTAssertEqual(ShareLinkBuilder.link(provider: .nextcloud, baseURL: "https://h", shareKey: "t"), "https://h/apps/photos/public/t")
        XCTAssertEqual(ShareLinkBuilder.link(provider: .photoprism, baseURL: "https://h", shareKey: "link|p|d|uid"), "https://h/s/link")
        XCTAssertEqual(ShareLinkBuilder.link(provider: .ente, baseURL: "x", shareKey: "acc|key"), "https://albums.ente.io?t=acc#key")
    }
}
