import XCTest
@testable import Frigate

final class EndpointTests: XCTestCase {
    func testConfigEndpoint() {
        let endpoint = Endpoint.config
        XCTAssertEqual(endpoint.path, "config")
        XCTAssertEqual(endpoint.method, .get)
        XCTAssertTrue(endpoint.query.isEmpty)
        XCTAssertNil(endpoint.body)
        XCTAssertTrue(endpoint.headers.isEmpty)
    }

    func testLoginEndpoint() throws {
        let endpoint = try Endpoint.login(LoginRequest(user: "admin", password: "s3cret"))
        XCTAssertEqual(endpoint.path, "login")
        XCTAssertEqual(endpoint.method, .post)
        XCTAssertEqual(endpoint.headers["Content-Type"], "application/json")

        let body = try XCTUnwrap(endpoint.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(json?["user"], "admin")
        XCTAssertEqual(json?["password"], "s3cret")
    }

    func testSnapshotEndpointWithoutHeight() {
        let endpoint = Endpoint.snapshot(camera: "front_door")
        XCTAssertEqual(endpoint.path, "front_door/latest.jpg")
        XCTAssertEqual(endpoint.method, .get)
        XCTAssertTrue(endpoint.query.isEmpty)
    }

    func testSnapshotEndpointWithHeightUsesHeightQueryKey() {
        // The server's query param is `height`, not the `h` a couple of PWA call sites use -
        // those are silently ignored server-side and serve full size instead of resizing.
        let endpoint = Endpoint.snapshot(camera: "front_door", height: 300)
        XCTAssertEqual(endpoint.query, [URLQueryItem(name: "height", value: "300")])
    }

    func testReviewEndpointOmitsEmptyFilters() {
        let endpoint = Endpoint.review()
        XCTAssertEqual(endpoint.path, "review")
        XCTAssertEqual(endpoint.basePath, "api")
        XCTAssertTrue(endpoint.query.isEmpty)
    }

    func testReviewEndpointIncludesProvidedFilters() {
        let endpoint = Endpoint.review(
            cameras: ["front_door", "backyard"],
            labels: ["person"],
            severity: .alert,
            before: 200,
            after: 100,
            limit: 50
        )
        XCTAssertEqual(endpoint.query, [
            URLQueryItem(name: "cameras", value: "front_door,backyard"),
            URLQueryItem(name: "labels", value: "person"),
            URLQueryItem(name: "severity", value: "alert"),
            URLQueryItem(name: "before", value: "200.0"),
            URLQueryItem(name: "after", value: "100.0"),
            URLQueryItem(name: "limit", value: "50"),
        ])
    }

    func testReviewEndpointOmitsReviewedWhenNil() {
        let endpoint = Endpoint.review(severity: .alert, reviewed: nil)
        XCTAssertFalse(
            endpoint.query.contains { $0.name == "reviewed" },
            "nil is the server's 'no filter' case, which is a third state - not the same as 0"
        )
    }

    func testReviewEndpointEncodesReviewedAsAnIntegerFlag() {
        XCTAssertEqual(
            Endpoint.review(reviewed: false).query,
            [URLQueryItem(name: "reviewed", value: "0")]
        )
        XCTAssertEqual(
            Endpoint.review(reviewed: true).query,
            [URLQueryItem(name: "reviewed", value: "1")]
        )
    }

    func testReviewPreviewMP4Endpoint() {
        let endpoint = Endpoint.reviewPreviewMP4(id: "abc123")
        XCTAssertEqual(endpoint.path, "review/abc123/preview")
        XCTAssertEqual(endpoint.basePath, "api")
        XCTAssertEqual(endpoint.query, [URLQueryItem(name: "format", value: "mp4")])
    }

    func testReviewThumbnailEndpointHasNoBasePath() {
        let endpoint = Endpoint.reviewThumbnail(path: "clips/review/thumb-front_door-abc.webp")
        XCTAssertEqual(endpoint.path, "clips/review/thumb-front_door-abc.webp")
        XCTAssertNil(endpoint.basePath)
    }

    func testReviewClipEndpointStaysUnderAPI() {
        let endpoint = Endpoint.reviewClip(id: "abc123")
        XCTAssertEqual(endpoint.path, "review/abc123/clip.mp4")
        XCTAssertEqual(endpoint.basePath, "api")
    }

    func testReviewClipHLSEndpointHasNoBasePath() {
        let endpoint = Endpoint.reviewClipHLS(camera: "front_door", start: 100, end: 200)
        XCTAssertEqual(endpoint.path, "vod/front_door/start/100.0/end/200.0/master.m3u8")
        XCTAssertNil(endpoint.basePath)
    }

    func testSetReviewedEndpoint() throws {
        let endpoint = try Endpoint.setReviewed(id: "abc123", reviewed: true)
        XCTAssertEqual(endpoint.path, "reviews/viewed")
        XCTAssertEqual(endpoint.method, .post)
        XCTAssertEqual(endpoint.headers["Content-Type"], "application/json")

        let body = try XCTUnwrap(endpoint.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["ids"] as? [String], ["abc123"])
        XCTAssertEqual(json?["reviewed"] as? Bool, true)
    }
}
