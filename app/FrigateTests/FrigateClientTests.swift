import XCTest
@testable import Frigate

final class FrigateClientTests: XCTestCase {
    private let baseURL = URL(string: "https://nvr.local:8971")!

    private func makeClient(credentials: CredentialProviding? = nil) -> FrigateClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return FrigateClient(baseURL: baseURL, credentials: credentials, session: session)
    }

    private func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFetchConfigDecodesAndComposesURL() async throws {
        let json = Data("""
        {
          "auth": {"enabled": true, "cookie_name": "frigate_token",
                   "session_length": 86400, "refresh_time": 1800},
          "cameras": {"front_door": {}, "backyard": {}}
        }
        """.utf8)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://nvr.local:8971/api/config")
            XCTAssertEqual(request.httpMethod, "GET")
            return (self.httpResponse(request.url!, 200), json)
        }

        let config = try await makeClient().fetchConfig()
        XCTAssertTrue(config.auth.enabled)
        XCTAssertEqual(config.auth.cookieName, "frigate_token")
        XCTAssertEqual(config.auth.sessionLength, 86400)
        XCTAssertEqual(config.auth.refreshTime, 1800)
        XCTAssertEqual(Set(config.cameras.keys), ["front_door", "backyard"])
    }

    func testUnauthorizedWithoutCredentials() async {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 401), Data())
        }
        await assertThrows(APIError.unauthorized) {
            _ = try await self.makeClient().fetchConfig()
        }
    }

    func testReauthenticatesOnceThenRetriesAndSucceeds() async throws {
        let json = Data(#"{"auth":{"enabled":false,"cookie_name":"frigate_token","session_length":86400,"refresh_time":1800},"cameras":{}}"#.utf8)
        let sequence = ResponseSequence([(401, Data()), (200, json)])
        MockURLProtocol.requestHandler = { request in
            let (status, body) = sequence.next()
            return (self.httpResponse(request.url!, status), body)
        }

        let counter = ReauthCounter()
        let client = makeClient(credentials: StubCredentials(counter: counter))
        let config = try await client.fetchConfig()

        XCTAssertFalse(config.auth.enabled)
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testSecondConsecutive401GivesUpWithoutLooping() async {
        let sequence = ResponseSequence([(401, Data()), (401, Data())])
        MockURLProtocol.requestHandler = { request in
            let (status, body) = sequence.next()
            return (self.httpResponse(request.url!, status), body)
        }

        let counter = ReauthCounter()
        let client = makeClient(credentials: StubCredentials(counter: counter))
        await assertThrows(APIError.unauthorized) {
            _ = try await client.fetchConfig()
        }
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testLoginMaps404ToAuthDisabled() async {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 404), Data())
        }
        await assertThrows(APIError.authDisabled) {
            try await self.makeClient().login(user: "a", password: "b")
        }
    }

    func testLoginMaps401ToUnauthorized() async {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 401), Data())
        }
        await assertThrows(APIError.unauthorized) {
            try await self.makeClient().login(user: "a", password: "b")
        }
    }

    func testMalformedJSONMapsToDecoding() async {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), Data("not json".utf8))
        }
        do {
            _ = try await makeClient().fetchConfig()
            XCTFail("expected a decoding error")
        } catch let error as APIError {
            guard case .decoding = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    func testTransportFailureMapsToTransport() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await makeClient().fetchConfig()
            XCTFail("expected a transport error")
        } catch let error as APIError {
            guard case .transport = error else {
                return XCTFail("expected .transport, got \(error)")
            }
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    // MARK: Helpers

    private func assertThrows(
        _ expected: APIError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected) to be thrown", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected APIError \(expected), got \(error)", file: file, line: line)
        }
    }
}

private actor ReauthCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct StubCredentials: CredentialProviding {
    let counter: ReauthCounter

    func reauthenticate(_ client: FrigateClient) async throws {
        await counter.increment()
    }
}
