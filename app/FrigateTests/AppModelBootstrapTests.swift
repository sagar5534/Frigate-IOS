import XCTest
@testable import Frigate

@MainActor
final class AppModelBootstrapTests: XCTestCase {
    private let baseURL = URL(string: "https://nvr.local:8971")!
    private let username = "admin"

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var credStore: InMemoryCredentialStore!
    private var configStore: ServerConfigStore!

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        credStore = InMemoryCredentialStore()
        configStore = ServerConfigStore(defaults: defaults)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeAppModel() -> AppModel {
        AppModel(session: mockProtocolSession(), credentialStore: credStore, configStore: configStore)
    }

    private nonisolated func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private nonisolated var configJSON: Data {
        Data(#"{"auth":{"enabled":true,"cookie_name":"frigate_token","session_length":86400,"refresh_time":1800},"cameras":{}}"#.utf8)
    }

    private func account() -> String {
        CredentialAccount.key(baseURL: baseURL, username: username)
    }

    // MARK: bootstrap

    func testBootstrapNothingStoredDisconnects() async {
        let appModel = makeAppModel()
        await appModel.bootstrap()
        guard case .disconnected = appModel.state else {
            return XCTFail("expected .disconnected, got \(appModel.state)")
        }
    }

    func testBootstrapWithConfigAndCredentialsConnects() async throws {
        configStore.save(ServerConfig(baseURL: baseURL, allowInsecure: false, username: username))
        try credStore.savePassword("hunter2", account: account())

        let json = configJSON
        MockURLProtocol.requestHandler = { request in
            if request.url?.lastPathComponent == "login" {
                return (self.response(request.url!, 200), Data())
            }
            return (self.response(request.url!, 200), json)
        }

        let appModel = makeAppModel()
        await appModel.bootstrap()

        guard case .connected = appModel.state else {
            return XCTFail("expected .connected, got \(appModel.state)")
        }
    }

    func testBootstrapWithStaleCredentialsFallsBackToNeedsAuth() async throws {
        configStore.save(ServerConfig(baseURL: baseURL, allowInsecure: false, username: username))
        try credStore.savePassword("outdated", account: account())

        // Login rejects the stale password.
        MockURLProtocol.requestHandler = { request in (self.response(request.url!, 401), Data()) }

        let appModel = makeAppModel()
        await appModel.bootstrap()

        guard case .needsAuth = appModel.state else {
            return XCTFail("expected .needsAuth, got \(appModel.state)")
        }
    }

    func testBootstrapWithConfigButNoPasswordNeedsAuth() async {
        configStore.save(ServerConfig(baseURL: baseURL, allowInsecure: false, username: username))
        // no password saved

        let appModel = makeAppModel()
        await appModel.bootstrap()

        guard case .needsAuth = appModel.state else {
            return XCTFail("expected .needsAuth, got \(appModel.state)")
        }
    }

    func testBootstrapAuthOffReconnects() async {
        configStore.save(ServerConfig(baseURL: baseURL, allowInsecure: false, username: nil))
        let json = configJSON
        MockURLProtocol.requestHandler = { request in (self.response(request.url!, 200), json) }

        let appModel = makeAppModel()
        await appModel.bootstrap()

        guard case .connected = appModel.state else {
            return XCTFail("expected .connected, got \(appModel.state)")
        }
    }

    // MARK: persistence side effects

    func testConnectAuthOffPersistsConfig() async {
        let json = configJSON
        MockURLProtocol.requestHandler = { request in (self.response(request.url!, 200), json) }

        let appModel = makeAppModel()
        try? await appModel.connect(baseURL: baseURL, allowInsecure: true)

        XCTAssertEqual(configStore.load(), ServerConfig(baseURL: baseURL, allowInsecure: true, username: nil))
    }

    func testSubmitLoginPersistsConfigAndPassword() async throws {
        // First reach .needsAuth via a probe.
        MockURLProtocol.requestHandler = { request in (self.response(request.url!, 401), Data()) }
        let appModel = makeAppModel()
        try? await appModel.connect(baseURL: baseURL, allowInsecure: false)

        let json = configJSON
        MockURLProtocol.requestHandler = { request in
            if request.url?.lastPathComponent == "login" {
                return (self.response(request.url!, 200), Data())
            }
            return (self.response(request.url!, 200), json)
        }
        try await appModel.submitLogin(user: username, password: "hunter2")

        XCTAssertEqual(configStore.load(), ServerConfig(baseURL: baseURL, allowInsecure: false, username: username))
        XCTAssertEqual(try credStore.password(account: account()), "hunter2")
    }

    func testLogoutClearsEverything() async {
        configStore.save(ServerConfig(baseURL: baseURL, allowInsecure: false, username: username))
        try? credStore.savePassword("hunter2", account: account())

        let appModel = makeAppModel()
        appModel.logout()

        guard case .disconnected = appModel.state else {
            return XCTFail("expected .disconnected, got \(appModel.state)")
        }
        XCTAssertNil(configStore.load())
        XCTAssertNil(try? credStore.password(account: account()))
    }
}
