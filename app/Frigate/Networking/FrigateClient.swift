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
        limit: Int? = nil
    ) async throws -> [ReviewSegment] {
        try await send(.review(cameras: cameras, labels: labels, severity: severity, before: before, after: after, limit: limit))
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
