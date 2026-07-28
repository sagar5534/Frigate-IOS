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
}
