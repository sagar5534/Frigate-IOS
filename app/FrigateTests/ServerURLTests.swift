import XCTest
@testable import Frigate

final class ServerURLTests: XCTestCase {
    func testBareHostDefaultsToHTTPS() throws {
        let url = try ServerURL.normalize("nvr.local")
        XCTAssertEqual(url.absoluteString, "https://nvr.local")
    }

    func testHostWithPortDefaultsToHTTPS() throws {
        let url = try ServerURL.normalize("nvr.local:8971")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "nvr.local")
        XCTAssertEqual(url.port, 8971)
    }

    func testExplicitSchemeIsPreserved() throws {
        let url = try ServerURL.normalize("http://nvr.local:5000")
        XCTAssertEqual(url.absoluteString, "http://nvr.local:5000")
    }

    func testTrailingSlashesAndWhitespaceStripped() throws {
        let url = try ServerURL.normalize("  https://nvr.local:8971///  ")
        XCTAssertEqual(url.absoluteString, "https://nvr.local:8971")
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try ServerURL.normalize("   "))
    }

    func testJunkInputThrows() {
        XCTAssertThrowsError(try ServerURL.normalize("not a url"))
    }

    func testWithSchemeRewritesScheme() throws {
        let https = try ServerURL.normalize("nvr.local:8971")
        let http = https.withScheme("http")
        XCTAssertEqual(http?.absoluteString, "http://nvr.local:8971")
    }
}
