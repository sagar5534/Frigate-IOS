import XCTest
@testable import Frigate

/// **Opt-in checks against a real Frigate server.** They are the P4 C2 gate: does the WebRTC
/// signaling socket actually open through nginx's `auth_request` with our session cookie, and is it
/// actually refused without one? No unit test can answer either question, and the answer decides
/// whether C3's binary dependency is worth adding.
///
/// Skipped unless the environment names a server, so the normal suite stays hermetic and offline.
///
/// **The `TEST_RUNNER_` prefix is required.** `xcodebuild` does not forward the invoking shell's
/// environment into the test process; variables prefixed `TEST_RUNNER_` on its command line are
/// forwarded with the prefix stripped, and nothing else is. Without it these tests silently skip.
///
/// ```
/// TEST_RUNNER_FRIGATE_TEST_URL=https://frigate.example.com \
/// TEST_RUNNER_FRIGATE_TEST_USER=admin \
/// TEST_RUNNER_FRIGATE_TEST_PASSWORD=… \
/// xcodebuild -project app/Frigate.xcodeproj -scheme Frigate \
///   -destination 'platform=iOS Simulator,name=iPhone 17' \
///   -only-testing:FrigateTests/LiveServerIntegrationTests test
/// ```
final class LiveServerIntegrationTests: XCTestCase {
    private struct Server {
        let baseURL: URL
        let user: String
        let password: String

        static func fromEnvironment() -> Server? {
            let env = ProcessInfo.processInfo.environment
            guard let urlString = env["FRIGATE_TEST_URL"],
                  let baseURL = URL(string: urlString),
                  let user = env["FRIGATE_TEST_USER"],
                  let password = env["FRIGATE_TEST_PASSWORD"]
            else { return nil }
            return Server(baseURL: baseURL, user: user, password: password)
        }
    }

    private func requireServer() throws -> Server {
        guard let server = Server.fromEnvironment() else {
            throw XCTSkip("""
                set TEST_RUNNER_FRIGATE_TEST_URL / _USER / _PASSWORD to run the live-server checks. \
                The TEST_RUNNER_ prefix is required: xcodebuild forwards only those into the test \
                process, stripping the prefix, and ignores the rest of the invoking shell's env.
                """)
        }
        return server
    }

    /// A session with its own cookie jar, so "logged in" and "not logged in" stay genuinely
    /// separate - the app's real client shares an App-Group jar, which would leak a token from one
    /// test into the next. Mirrors the real client's cookie policy otherwise.
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }

    /// Opens the socket and waits for a pong. A ping only round-trips once the HTTP upgrade has
    /// actually succeeded, so this distinguishes "nginx let us through" from "nginx returned 401"
    /// without needing an SDP offer we can't produce until libwebrtc lands in C3.
    private func openAndPing(_ request: URLRequest, session: URLSession) async throws {
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// The gate. Also exercises C1's resolution against a real `/api/config` rather than a fixture:
    /// the `src` we send is whatever `LiveStreamSource` decided, not a hand-written stream name.
    func testSignalingSocketOpensForARestreamedCameraWithTheSessionCookie() async throws {
        let server = try requireServer()
        let client = FrigateClient(baseURL: server.baseURL, session: makeSession())

        try await client.login(user: server.user, password: server.password)
        let config = try await client.fetchConfig()

        // Print what every camera declares alongside what we picked. The declared list is the part
        // that matters: `LiveStreamSource` only has to guess when a camera offers several streams
        // and none is named after the camera, so this is how we find out whether that guess is
        // actually load-bearing on a real config or purely theoretical.
        let resolved = config.enabledCameraNames.map { ($0, LiveStreamSource.ladder(camera: $0, config: config)) }
        for (camera, ladder) in resolved {
            let declared = config.cameras[camera]?.live.streams.map { "\($0.label)=\($0.name)" } ?? []
            print("[P4] \(camera) -> \(ladder.first.map(String.init(describing:)) ?? "none") | declared: \(declared.joined(separator: ", "))")
        }

        let restreamed = resolved.compactMap { camera, ladder -> String? in
            guard case .webrtc(let streamName) = ladder.first else { return nil }
            return streamName
        }
        guard let streamName = restreamed.first else {
            throw XCTSkip("no enabled camera on this server resolves to WebRTC - nothing to open")
        }

        let request = try await client.webSocketRequest(for: .webrtcWebSocket(src: streamName))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Cookie"), "login should have produced a session cookie")

        try await openAndPing(request, session: makeSession())
    }

    /// The other half: if the socket opens without a cookie too, then `auth_request` is not
    /// actually protecting this route and the "belt" cookie in `webSocketRequest` is load-bearing
    /// for nothing. Worth knowing either way.
    func testSignalingSocketIsRefusedWithoutTheSessionCookie() async throws {
        let server = try requireServer()
        let authedClient = FrigateClient(baseURL: server.baseURL, session: makeSession())
        try await authedClient.login(user: server.user, password: server.password)
        let config = try await authedClient.fetchConfig()

        guard config.auth.enabled else {
            throw XCTSkip("auth is disabled on this server, so an unauthenticated socket is expected to succeed")
        }
        guard let streamName = config.go2rtc.streamNames.sorted().first else {
            throw XCTSkip("no go2rtc streams configured on this server")
        }

        // A client that never logged in: same URL composition, empty cookie jar.
        let anonymous = FrigateClient(baseURL: server.baseURL, session: makeSession())
        let request = try await anonymous.webSocketRequest(for: .webrtcWebSocket(src: streamName))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))

        do {
            try await openAndPing(request, session: makeSession())
            XCTFail("nginx accepted an unauthenticated signaling socket")
        } catch {
            // Expected: the upgrade fails, so the ping never round-trips.
        }
    }
}
