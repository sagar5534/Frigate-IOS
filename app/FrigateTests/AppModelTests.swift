import XCTest
@testable import Frigate

@MainActor
final class AppModelTests: XCTestCase {
    private let baseURL = URL(string: "https://nvr.local:8971")!

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private nonisolated func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private nonisolated var configJSON: Data {
        Data(#"{"auth":{"enabled":true,"cookie_name":"frigate_token","session_length":86400,"refresh_time":1800},"cameras":{"front_door":{}}}"#.utf8)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeNeedsAuth() async -> AppModel {
        MockURLProtocol.requestHandler = { request in (self.response(request.url!, 401), Data()) }
        let appModel = makeTestAppModel(session: mockSession())
        try? await appModel.connect(baseURL: baseURL, allowInsecure: false)
        return appModel
    }

    // MARK: connect

    func testConnect200Connects() async {
        let json = configJSON
        MockURLProtocol.requestHandler = { request in (self.response(request.url!, 200), json) }
        let appModel = makeTestAppModel(session: mockSession())

        try? await appModel.connect(baseURL: baseURL, allowInsecure: false)

        guard case .connected = appModel.state else {
            return XCTFail("expected .connected, got \(appModel.state)")
        }
        XCTAssertEqual(appModel.baseURL, baseURL)
    }

    func testConnect401RoutesToNeedsAuth() async {
        MockURLProtocol.requestHandler = { request in (self.response(request.url!, 401), Data()) }
        let appModel = makeTestAppModel(session: mockSession())

        try? await appModel.connect(baseURL: baseURL, allowInsecure: false)

        guard case .needsAuth = appModel.state else {
            return XCTFail("expected .needsAuth, got \(appModel.state)")
        }
    }

    // MARK: submitLogin

    func testSubmitLoginSuccessConnects() async throws {
        let appModel = await makeNeedsAuth()

        let json = configJSON
        MockURLProtocol.requestHandler = { request in
            if request.url?.lastPathComponent == "login" {
                return (self.response(request.url!, 200), Data())
            }
            return (self.response(request.url!, 200), json)
        }

        try await appModel.submitLogin(user: "admin", password: "secret")

        guard case .connected = appModel.state else {
            return XCTFail("expected .connected, got \(appModel.state)")
        }
    }

    func testSubmitLoginBadCredentialsThrowsAndStaysNeedsAuth() async {
        let appModel = await makeNeedsAuth()

        MockURLProtocol.requestHandler = { request in (self.response(request.url!, 401), Data()) }

        do {
            try await appModel.submitLogin(user: "admin", password: "wrong")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("expected APIError, got \(error)")
        }

        guard case .needsAuth = appModel.state else {
            return XCTFail("expected to stay .needsAuth, got \(appModel.state)")
        }
    }

    func testSubmitLoginAuthDisabledReprobesToConnected() async throws {
        let appModel = await makeNeedsAuth()

        let json = configJSON
        MockURLProtocol.requestHandler = { request in
            if request.url?.lastPathComponent == "login" {
                return (self.response(request.url!, 404), Data())
            }
            return (self.response(request.url!, 200), json)
        }

        try await appModel.submitLogin(user: "admin", password: "secret")

        guard case .connected = appModel.state else {
            return XCTFail("expected .connected, got \(appModel.state)")
        }
    }
}
