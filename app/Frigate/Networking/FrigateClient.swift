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
            // A private jar so servers don't cross-contaminate and so the login `Set-Cookie` is
            // captured and auto-refreshed for the life of this client.
            config.httpCookieStorage = HTTPCookieStorage()
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

    private func makeRequest(_ endpoint: Endpoint) throws -> URLRequest {
        let apiURL = baseURL.appending(path: "api").appending(path: endpoint.path)
        guard var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }
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
}
