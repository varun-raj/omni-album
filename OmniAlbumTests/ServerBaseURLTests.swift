import XCTest
@testable import OmniAlbum

final class ServerBaseURLTests: XCTestCase {
    private func make(_ url: String, _ marker: String?) -> String? {
        ServerBaseURL.make(URL(string: url)!, prefixBefore: marker)
    }

    func testShareLinkAtRoot() {
        XCTAssertEqual(make("https://host/share/KEY", "/share/"), "https://host")
    }

    func testKeepsInstallPrefix() {
        XCTAssertEqual(make("https://host/immich/share/KEY?key=a", "/share/"), "https://host/immich")
        XCTAssertEqual(make("http://host:8080/a/b/s/tok/slug", "/s/"), "http://host:8080/a/b")
        XCTAssertEqual(make("https://host:443/nc/apps/photos/public/T", "/apps/photos/public/"), "https://host/nc")
    }

    func testNormalizeAddsSchemeAndDropsTrailingSlashQueryFragment() {
        XCTAssertEqual(ServerBaseURL.normalize("host.example/immich/"), "https://host.example/immich")
        XCTAssertEqual(ServerBaseURL.normalize("https://host/?x=1#y"), "https://host")
        XCTAssertEqual(ServerBaseURL.normalize("  https://host  "), "https://host")
    }
}

final class ImmichShareLinkTests: XCTestCase {
    func testKeyInPath() throws {
        let parsed = try ImmichShareLink.parse("https://photos.example.com/share/abc123")
        XCTAssertEqual(parsed.baseURL, "https://photos.example.com")
        XCTAssertEqual(parsed.key, "abc123")
        XCTAssertEqual(parsed.token, "abc123")
        XCTAssertNil(parsed.slug)
    }

    func testSlugWithKeyQuery() throws {
        let parsed = try ImmichShareLink.parse("https://photos.example.com/share/my-slug?key=K")
        XCTAssertEqual(parsed.key, "K")
        XCTAssertEqual(parsed.slug, "my-slug")
    }

    func testSubpathInstall() throws {
        let parsed = try ImmichShareLink.parse("https://example.com/immich/share/abc")
        XCTAssertEqual(parsed.baseURL, "https://example.com/immich")
    }

    func testRejectsNonShareLinks() {
        XCTAssertThrowsError(try ImmichShareLink.parse("https://example.com/albums/1"))
    }
}
