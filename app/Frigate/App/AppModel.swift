import Foundation
import Observation

/// Root connection state. Owns the live `FrigateClient` and (once connected) the `FrigateConfig`,
/// and is injected into the SwiftUI environment for the root view to switch on. Also owns
/// persistence: on a successful connect/login it saves the `ServerConfig` (+ password in the
/// Keychain) so `bootstrap()` can auto-connect on the next launch.
@MainActor
@Observable
final class AppModel {
    enum State {
        case disconnected                             // show ServerSetup
        case connecting                               // launch-time auto-connect in progress
        case needsAuth(FrigateClient)                 // reachable, auth on
        case connected(FrigateClient, FrigateConfig)  // ready (main app placeholder for now)
    }

    private(set) var state: State = .disconnected

    /// The base URL of the connected/authenticating server. Surfaced on the login screen and used
    /// to build clients + account keys.
    private(set) var baseURL: URL?
    private var allowInsecure = false

    /// Injected in tests so clients probe a mock session; nil in production (real networking).
    private let session: URLSession?
    private let credentialStore: CredentialStoring
    private let configStore: ServerConfigStore

    init(
        session: URLSession? = nil,
        credentialStore: CredentialStoring? = nil,
        configStore: ServerConfigStore? = nil
    ) {
        self.session = session
        self.credentialStore = credentialStore ?? KeychainCredentialStore()
        self.configStore = configStore ?? ServerConfigStore()
    }

    // MARK: Launch

    /// At launch, reconnect to the saved server if there is one. The in-memory cookie jar doesn't
    /// survive relaunch, so an auth-on server is re-logged-in for a fresh cookie. Stale/missing
    /// credentials fall back to the login screen; nothing saved -> the setup screen.
    func bootstrap() async {
        guard let config = configStore.load() else {
            state = .disconnected
            return
        }
        baseURL = config.baseURL
        allowInsecure = config.allowInsecure
        state = .connecting

        if let username = config.username {
            let account = CredentialAccount.key(baseURL: config.baseURL, username: username)
            guard let password = try? credentialStore.password(account: account), !password.isEmpty else {
                state = .needsAuth(makeClient(baseURL: config.baseURL, username: nil))
                return
            }
            let client = makeClient(baseURL: config.baseURL, username: username)
            do {
                try await client.login(user: username, password: password)
                let frigateConfig = try await client.fetchConfig()
                state = .connected(client, frigateConfig)
            } catch {
                state = .needsAuth(makeClient(baseURL: config.baseURL, username: nil))
            }
        } else {
            let client = makeClient(baseURL: config.baseURL, username: nil)
            do {
                let frigateConfig = try await client.fetchConfig()
                state = .connected(client, frigateConfig)
            } catch APIError.unauthorized {
                state = .needsAuth(client)
            } catch {
                state = .disconnected
            }
        }
    }

    // MARK: Connect / login

    /// Probe the server (with a one-shot http:// fallback on transport failure) and transition.
    /// Interpreted by HTTP status, not `auth.enabled` (only readable once authorized): a decoded
    /// config (`200`) -> `.connected` (auth off, config persisted); `401` -> `.needsAuth`. Throws
    /// `APIError` on failure so the setup screen can show a message; `state` is left untouched then,
    /// keeping the setup screen (and its typed input) mounted.
    func connect(baseURL: URL, allowInsecure: Bool) async throws {
        self.allowInsecure = allowInsecure
        do {
            try await attempt(baseURL)
        } catch let error as APIError {
            // Transport failure -> retry once over http:// (auth-off port 5000 / plain-HTTP LAN).
            guard case .transport = error, let httpURL = baseURL.withScheme("http"), httpURL != baseURL else {
                throw error
            }
            try await attempt(httpURL)
        }
    }

    private func attempt(_ baseURL: URL) async throws {
        let client = makeClient(baseURL: baseURL, username: nil)
        do {
            let config = try await client.fetchConfig()
            self.baseURL = baseURL
            persistConfig(username: nil)
            state = .connected(client, config)
        } catch APIError.unauthorized {
            self.baseURL = baseURL
            state = .needsAuth(client)
        }
    }

    /// Log in for the current server, then re-probe to reach `.connected`. Builds a client wired
    /// with the credential provider so later `401`s re-login silently. Throws `APIError` so the
    /// login screen can map it to a message; on success, persists config + password. A `404`
    /// (auth turned off between probe and submit) is swallowed and the re-probe proceeds.
    func submitLogin(user: String, password: String) async throws {
        guard let baseURL else { return }
        let client = makeClient(baseURL: baseURL, username: user)
        do {
            try await client.login(user: user, password: password)
        } catch APIError.authDisabled {
            // Auth was disabled server-side; fall through to the unauthenticated re-probe.
        }
        let config = try await client.fetchConfig()

        try? credentialStore.savePassword(password, account: CredentialAccount.key(baseURL: baseURL, username: user))
        persistConfig(username: user)
        state = .connected(client, config)
    }

    /// Forget the server: drop the client (its cookie jar dies with it), clear stored credentials
    /// and config, and return to the setup screen.
    func logout() {
        try? credentialStore.clear()
        configStore.clear()
        baseURL = nil
        allowInsecure = false
        state = .disconnected
    }

    // MARK: Helpers

    private func makeClient(baseURL: URL, username: String?) -> FrigateClient {
        let provider: CredentialProviding? = username.map {
            KeychainCredentialProvider(store: credentialStore, baseURL: baseURL, username: $0)
        }
        return FrigateClient(
            baseURL: baseURL,
            allowInsecure: allowInsecure,
            credentials: provider,
            credentialStore: credentialStore,
            session: session
        )
    }

    private func persistConfig(username: String?) {
        guard let baseURL else { return }
        configStore.save(ServerConfig(baseURL: baseURL, allowInsecure: allowInsecure, username: username))
    }
}
