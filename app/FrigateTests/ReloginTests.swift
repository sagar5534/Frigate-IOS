import XCTest
@testable import Frigate

/// C5: the silent 401 -> re-login -> retry path wired through the real `KeychainCredentialProvider`
/// plus the token-mirror side effect.
final class ReloginTests: XCTestCase {
    private let baseURL = URL(string: "https://nvr.local:8971")!
    private let username = "admin"

    private var account: String { CredentialAccount.key(baseURL: baseURL, username: username) }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private var configJSON: Data {
        Data(#"{"auth":{"enabled":true,"cookie_name":"frigate_token","session_length":86400,"refresh_time":1800},"cameras":{}}"#.utf8)
    }

    private func response(_ url: URL, _ status: Int, setCookie: String? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let setCookie { headers["Set-Cookie"] = setCookie }
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    private func makeClient(store: CredentialStoring) -> FrigateClient {
        let provider = KeychainCredentialProvider(store: store, baseURL: baseURL, username: username)
        return FrigateClient(baseURL: baseURL, credentials: provider, credentialStore: store, session: mockSession())
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSilentReloginSucceedsAndMirrorsToken() async throws {
        let store = InMemoryCredentialStore()
        try store.savePassword("hunter2", account: account)

        let configCalls = Counter()
        let json = configJSON
        MockURLProtocol.requestHandler = { request in
            if request.url?.lastPathComponent == "login" {
                return (self.response(request.url!, 200, setCookie: "frigate_token=jwt-xyz; Path=/; HttpOnly"), Data())
            }
            let n = configCalls.increment()
            return n == 1
                ? (self.response(request.url!, 401), Data())
                : (self.response(request.url!, 200), json)
        }

        let client = makeClient(store: store)
        _ = try await client.fetchConfig()

        XCTAssertEqual(try store.token(), "jwt-xyz")
    }

    func testNoStoredPasswordSurfacesUnauthorized() async {
        let store = InMemoryCredentialStore() // empty
        MockURLProtocol.requestHandler = { request in (self.response(request.url!, 401), Data()) }

        do {
            _ = try await makeClient(store: store).fetchConfig()
            XCTFail("expected unauthorized")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    func testBadStoredPasswordDoesNotLoop() async {
        let store = InMemoryCredentialStore()
        try? store.savePassword("wrong", account: account)
        // /config always 401; /login always 401 (bad password). Must terminate, not recurse.
        MockURLProtocol.requestHandler = { request in (self.response(request.url!, 401), Data()) }

        do {
            _ = try await makeClient(store: store).fetchConfig()
            XCTFail("expected unauthorized")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    func testRetryStillUnauthorizedGivesUp() async {
        let store = InMemoryCredentialStore()
        try? store.savePassword("hunter2", account: account)
        // login "succeeds" but the retried config is still 401 -> give up once, no loop.
        MockURLProtocol.requestHandler = { request in
            if request.url?.lastPathComponent == "login" {
                return (self.response(request.url!, 200), Data())
            }
            return (self.response(request.url!, 401), Data())
        }

        do {
            _ = try await makeClient(store: store).fetchConfig()
            XCTFail("expected unauthorized")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    func testRefreshedSetCookieIsMirrored() async throws {
        let store = InMemoryCredentialStore()
        MockURLProtocol.requestHandler = { request in
            (self.response(request.url!, 200, setCookie: "frigate_token=refreshed; Path=/"), self.configJSON)
        }

        let client = FrigateClient(baseURL: baseURL, credentialStore: store, session: mockSession())
        _ = try await client.fetchConfig()

        XCTAssertEqual(try store.token(), "refreshed")
    }
}
