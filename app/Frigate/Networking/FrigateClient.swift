import Foundation

/// The single entry point for every Frigate HTTP call. Feature code never touches `URLSession`;
/// it calls typed methods (`fetchConfig()`, `login(...)`) or builds an `Endpoint` and calls the
/// generic `send(_:)`. An `actor` because it owns mutable session/auth state and must serialize
/// the `401 -> re-login -> retry` dance without races.
actor FrigateClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let credentials: CredentialProviding?
    // Mirrors the (re)issued `frigate_token` into the shared store so the NSE's snapshot fetch keeps
    // working (P5); nil when there's nothing to persist to.
    private let credentialStore: CredentialStoring?
    // Retained so the delegate outlives the client; the session holds only a weak reference.
    private let trustDelegate: InsecureTrustDelegate?

    static let tokenCookieName = "frigate_token"

    init(
        baseURL: URL,
        allowInsecure: Bool = false,
        credentials: CredentialProviding? = nil,
        credentialStore: CredentialStoring? = nil,
        session: URLSession? = nil,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.credentialStore = credentialStore
        self.decoder = decoder

        if let session {
            self.session = session
            self.trustDelegate = nil
        } else {
            let config = URLSessionConfiguration.default
            config.httpCookieAcceptPolicy = .always
            config.httpShouldSetCookies = true
            // The bare `HTTPCookieStorage()` initializer produces a jar URLSession doesn't reliably
            // capture Set-Cookie into - the app-group-backed variant is the one that actually works,
            // and happens to double as the store the future Notification Service Extension can share.
            config.httpCookieStorage = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: ServerConfigStore.appGroupSuite)
            if allowInsecure {
                let delegate = InsecureTrustDelegate(allowInsecure: true)
                self.trustDelegate = delegate
                self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            } else {
                self.trustDelegate = nil
                self.session = URLSession(configuration: config)
            }
        }
    }

    // MARK: Public surface

    func send<Response: Decodable>(_ endpoint: Endpoint, as type: Response.Type = Response.self) async throws -> Response {
        let (data, _) = try await send(endpoint, allowRetry: true)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    /// Send a request and discard the response body (e.g. login, whose JWT arrives as a cookie).
    func send(_ endpoint: Endpoint) async throws {
        _ = try await send(endpoint, allowRetry: true)
    }

    /// Raw response bytes, for binary endpoints (snapshots/clips in P2/P3).
    func data(for endpoint: Endpoint) async throws -> Data {
        let (data, _) = try await send(endpoint, allowRetry: true)
        return data
    }

    /// A response that never ends, delivered as it arrives - the MJPEG live feed (P4.2), which is
    /// one HTTP response streaming `multipart/x-mixed-replace` parts forever. `send`/`data` are
    /// wrong for it by construction: they buffer to completion, and this response never completes.
    ///
    /// Same auth story as everything else: the session attaches the cookie jar, and a `401` gets
    /// one silent re-login + retry before surfacing.
    func byteStream(for endpoint: Endpoint) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try await byteStream(for: endpoint, allowRetry: true)
    }

    private func byteStream(
        for endpoint: Endpoint,
        allowRetry: Bool
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let request = try makeRequest(endpoint)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let urlError as URLError {
            throw APIError.transport(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200...299:
            return (bytes, http)
        case 401:
            // The failed response's transfer must be cancelled explicitly - `data(for:)` reads
            // bodies to completion, but an abandoned byte stream would otherwise hold its
            // connection (and, for the MJPEG feed, a per-client encoder on the server) open.
            bytes.task.cancel()
            if allowRetry, let credentials {
                try await credentials.reauthenticate(self)
                return try await byteStream(for: endpoint, allowRetry: false)
            }
            throw APIError.unauthorized
        default:
            bytes.task.cancel()
            throw APIError.http(status: http.statusCode, body: Data())
        }
    }

    // MARK: Core

    private func endpointURL(_ endpoint: Endpoint) throws -> URL {
        let root = endpoint.basePath.map { baseURL.appending(path: $0) } ?? baseURL
        let apiURL = root.appending(path: endpoint.path)
        guard var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }
        return url
    }

    private func makeRequest(_ endpoint: Endpoint) throws -> URLRequest {
        let url = try endpointURL(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = endpoint.body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    private func send(_ endpoint: Endpoint, allowRetry: Bool) async throws -> (Data, HTTPURLResponse) {
        let request = try makeRequest(endpoint)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw APIError.transport(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200...299:
            await persistRefreshedToken(from: http)
            return (data, http)
        case 401:
            // Never re-auth the login request itself - that would recurse forever on a bad password.
            if allowRetry, endpoint.path != "login", let credentials {
                try await credentials.reauthenticate(self)
                return try await send(endpoint, allowRetry: false)
            }
            throw APIError.unauthorized
        case 404 where endpoint.path == "login":
            throw APIError.authDisabled
        default:
            throw APIError.http(status: http.statusCode, body: data)
        }
    }

    /// The server sends a `frigate_token` `Set-Cookie` on login and on refresh (within
    /// `refresh_time`). Whenever we see one, mirror it into the shared store so the NSE stays current.
    /// The session's own cookie jar still handles attaching it to subsequent requests.
    private func persistRefreshedToken(from response: HTTPURLResponse) async {
        guard let credentialStore,
              let url = response.url,
              let headers = response.allHeaderFields as? [String: String]
        else { return }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard let token = cookies.first(where: { $0.name == Self.tokenCookieName })?.value else { return }
        try? await credentialStore.saveToken(token)
    }
}

// MARK: Typed conveniences

extension FrigateClient {
    func fetchConfig() async throws -> FrigateConfig {
        try await send(.config)
    }

    /// Logs in and lets the session cookie jar capture the `frigate_token` cookie. A `404` maps to
    /// `.authDisabled` (auth is off) so callers can distinguish it from `401` (bad credentials).
    func login(user: String, password: String) async throws {
        let endpoint = try Endpoint.login(LoginRequest(user: user, password: password))
        try await send(endpoint)
    }

    /// JPEG bytes for a camera's latest frame. Goes through `data(for:)` so a stale cookie still
    /// gets the same silent re-login + retry as JSON endpoints.
    func snapshot(camera: String, height: Int? = nil) async throws -> Data {
        try await data(for: .snapshot(camera: camera, height: height))
    }

    func fetchReviews(
        cameras: [String] = [],
        labels: [String] = [],
        severity: ReviewSegment.Severity? = nil,
        before: Double? = nil,
        after: Double? = nil,
        limit: Int? = nil,
        reviewed: Bool? = nil
    ) async throws -> [ReviewSegment] {
        try await send(.review(
            cameras: cameras,
            labels: labels,
            severity: severity,
            before: before,
            after: after,
            limit: limit,
            reviewed: reviewed
        ))
    }

    /// Raw webp bytes for a review segment's thumbnail (`path` is `ReviewSegment.thumbnailPath`).
    func reviewThumbnail(path: String) async throws -> Data {
        try await data(for: .reviewThumbnail(path: path))
    }

    func setReviewed(id: String, reviewed: Bool) async throws {
        try await send(.setReviewed(id: id, reviewed: reviewed))
    }

    /// Fully-resolved URL for a base-relative endpoint, for handing to AVPlayer/AVURLAsset.
    func authedURL(for endpoint: Endpoint) -> URL? {
        try? endpointURL(endpoint)
    }

    /// The session's current cookies for `url`, so `AVURLAsset` can be given
    /// `AVURLAssetHTTPCookiesKey` - AVFoundation does not consult `URLSession`'s cookie jar itself.
    func sessionCookies(for url: URL) -> [HTTPCookie] {
        session.configuration.httpCookieStorage?.cookies(for: url) ?? []
    }
}

// MARK: WebSockets (P4 live view)

extension FrigateClient {
    /// Re-runs `/api/login` so a stale session cookie is replaced.
    ///
    /// Every ordinary request self-heals on a `401` through the retry seam, but a WebSocket
    /// handshake has no such path: it carries whatever cookie the jar held and simply fails. The
    /// live-view retry calls this once so an expired session recovers instead of being reported as
    /// an unresponsive server. Silent on failure - the caller is already in a retry, and the error
    /// it eventually reports is more informative than one from here.
    func refreshSession() async {
        guard let credentials else { return }
        try? await credentials.reauthenticate(self)
    }

    /// The exact handshake request `liveSocket(for:)` will use. Public for tests and for logging a
    /// failed live connection - when a socket is refused, the request that was refused is the
    /// single most useful thing to see.
    func webSocketRequest(for endpoint: Endpoint) throws -> URLRequest {
        let httpURL = try endpointURL(endpoint)
        guard let socketURL = Self.webSocketScheme(httpURL) else { throw APIError.invalidURL }

        var request = URLRequest(url: socketURL)
        for (field, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        // nginx gates `/live/webrtc/api/ws` with the same `auth_request` as `/clips/` and `/vod/`,
        // so the handshake needs `frigate_token`. The session would normally attach jar cookies
        // itself, but set them explicitly as a belt - a silent miss here surfaces as an unexplained
        // server rejection, which is the most expensive kind of bug to chase.
        //
        // Note the lookup uses the **http(s)** URL, not the ws(s) one: `HTTPCookieStorage` decides
        // whether to hand back `Secure` cookies by looking at the URL's scheme, and `wss` is not on
        // its list of secure schemes.
        let cookies = session.configuration.httpCookieStorage?.cookies(for: httpURL) ?? []
        if !cookies.isEmpty {
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        return request
    }

    /// A signaling socket built from this client's own `URLSession`, so it inherits the shared
    /// cookie jar and the `InsecureTrustDelegate`. Call `start()` on the result to connect.
    func liveSocket(for endpoint: Endpoint) throws -> LiveSocket {
        LiveSocket(task: session.webSocketTask(with: try webSocketRequest(for: endpoint)))
    }

    private static func webSocketScheme(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        return components.url
    }
}
