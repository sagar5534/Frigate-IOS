import XCTest
@testable import Frigate

@MainActor
final class ServerSetupModelTests: XCTestCase {
    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func configJSON(authEnabled: Bool) -> Data {
        Data(#"{"auth":{"enabled":\#(authEnabled),"cookie_name":"frigate_token","session_length":86400,"refresh_time":1800},"cameras":{}}"#.utf8)
    }

    private nonisolated func ok(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testReachable200Connects() async {
        let json = configJSON(authEnabled: false)
        MockURLProtocol.requestHandler = { request in (self.ok(request.url!), json) }

        let session = mockSession()
        let appModel = makeTestAppModel(session: session)
        let model = ServerSetupModel()
        model.urlText = "nvr.local:8971"

        await model.testConnection(appModel)

        guard case .connected = appModel.state else {
            return XCTFail("expected .connected, got \(appModel.state)")
        }
        XCTAssertEqual(model.phase, .idle)
    }

    func testReachable401RoutesToNeedsAuth() async {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }

        let session = mockSession()
        let appModel = makeTestAppModel(session: session)
        let model = ServerSetupModel()
        model.urlText = "nvr.local:8971"

        await model.testConnection(appModel)

        guard case .needsAuth = appModel.state else {
            return XCTFail("expected .needsAuth, got \(appModel.state)")
        }
    }

    func testTransportThenHTTPFallbackConnects() async {
        let json = configJSON(authEnabled: false)
        MockURLProtocol.requestHandler = { request in
            if request.url?.scheme == "https" {
                throw URLError(.cannotConnectToHost)
            }
            return (self.ok(request.url!), json)
        }

        let session = mockSession()
        let appModel = makeTestAppModel(session: session)
        let model = ServerSetupModel()
        model.urlText = "nvr.local:5000"

        await model.testConnection(appModel)

        guard case .connected = appModel.state else {
            return XCTFail("expected .connected via http fallback, got \(appModel.state)")
        }
    }

    func testHardTransportFails() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }

        let session = mockSession()
        let appModel = makeTestAppModel(session: session)
        let model = ServerSetupModel()
        model.urlText = "nvr.local:8971"

        await model.testConnection(appModel)

        guard case .failed = model.phase else {
            return XCTFail("expected model.phase .failed, got \(model.phase)")
        }
    }

    func testInvalidURLFails() async {
        let session = mockSession()
        let appModel = makeTestAppModel(session: session)
        let model = ServerSetupModel()
        model.urlText = "not a url"

        await model.testConnection(appModel)

        guard case .failed = model.phase else {
            return XCTFail("expected .failed, got \(model.phase)")
        }
    }
}
