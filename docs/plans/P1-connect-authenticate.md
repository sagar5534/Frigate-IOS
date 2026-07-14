# P1 - Connect & Authenticate

## Context

P0 is done (the template app builds, installs, and runs on a physical iPhone). P1 is the
foundation every later feature stands on: let a user point the app at their Frigate server, log
in (or connect with auth off), and stay connected across restarts. Nothing else (cameras,
events, live video) can be built until there is a reliable, reusable way to talk to Frigate's
HTTP API and hold an authenticated session.

This plan defines the **full P1 architecture**, breaks P1 into **6 individually-plannable
chunks (C1-C6)**, and then **fully details C1 (the shared API client)**. C2-C6 are outlined
here as one-paragraph summaries and will each get their own `/plan` session when we start them.

Branch: `p1-connect-authenticate` (already created off `main`).

### Verified Frigate API facts (from `~/Documents/frigate`, read directly)

- **Login**: `POST /api/login`, body `{"user": string, "password": string}`
  (`frigate/api/defs/request/app_body.py` `AppPostLoginBody`). On success returns an
  **empty `200`** with the JWT delivered **only** as a `Set-Cookie` header - default cookie
  name `frigate_token` (`frigate/api/auth.py:848-882`, `set_jwt_cookie`). **Not in the body.**
- **Auth disabled**: `POST /api/login` returns **`404`** `{"message":"Authentication is
  disabled"}` (`auth.py:849-852`).
- **Session config** (`frigate/config/auth.py`): `cookie_name` default `frigate_token`,
  `session_length` `86400`s (24h), `refresh_time` `1800`s, `cookie_secure` default `false`.
- **Auto-refresh**: the server issues a fresh `Set-Cookie` when a request arrives within
  `refresh_time` of expiry **only if the token came in as a cookie** (not a Bearer header)
  (`auth.py` refresh path). => cookie-based auth is the correct choice; a stored `URLSession`
  cookie jar honors the refresh for free.
- **No long-lived API key / refresh token exists.** Once a JWT fully expires, the only way back
  is another `POST /api/login`. This is why we store the password (see C4).
- **Auth-mode detection**: `GET /api/config` (dependency `allow_any_authenticated`) returns
  `200` when auth is off (or the cookie is valid) and `401` when auth is on and we are
  unauthenticated. That single probe distinguishes the two modes.
- **CSRF**: enforced only when an `Origin` header is present (`frigate/api/fastapi_app.py:49-55`
  `check_csrf`). A native `URLSession` sends no `Origin`, so CSRF never triggers. We will not
  set one. (Harmless to add `X-CSRF-TOKEN: 1` later if ever needed.)
- **Config shape** (`frigate/api/app.py` config route): top-level `auth` block
  (`enabled`, `cookie_name`, `session_length`, `refresh_time`, `roles`) and top-level
  `cameras` object keyed by camera name.

### Decisions locked with the user

1. **This plan** = architecture overview + C1-C6 map, with **C1 fully detailed**; C2-C6 get
   their own plans later.
2. **Self-signed certs** = a simple **"Allow insecure connections" toggle** per server (skips
   TLS validation for that host). No cert-pinning UI.
3. **Credentials** = store the **password in the shared App-Group Keychain** so the app (and,
   later, the Notification Service Extension) can silently re-login on 401/expiry and stay
   logged in indefinitely.

---

## Architecture overview

Introduce a clean, layered structure under `app/Frigate/` (currently flat: just
`FrigateApp.swift` + `ContentView.swift`). Groups:

```
app/Frigate/
  App/            FrigateApp.swift, AppModel (root @Observable state), root view switch
  Models/         Codable API types (FrigateConfig, LoginRequest, ...)
  Networking/     FrigateClient (actor), Endpoint, HTTPMethod, APIError,
                  InsecureTrustDelegate, CredentialProviding
  Storage/        ServerConfigStore (App-Group UserDefaults), CredentialStore (Keychain)  [C4/C6]
  Features/
    ServerSetup/  view + view model                                                        [C2]
    Login/        view + view model                                                        [C3]
  Shared/         reusable UI bits
```

**Layers and the seams that make them reusable:**

- **`FrigateClient` (actor)** - the single entry point for every Frigate HTTP call, now and
  for all future features (cameras, events, live negotiation). Feature code never touches
  `URLSession`; it calls typed methods (`fetchConfig()`, `login(...)`) or, for new endpoints,
  builds an `Endpoint` value and calls the generic `send(_:)`. Adding an API = add one
  `Endpoint` + one `Codable` model. An `actor` because it owns mutable session/auth state and
  must serialize the 401 -> re-login -> retry dance without races.
- **`Endpoint`** - a value type describing one request (path, method, query, body, headers).
  Keeps call sites declarative and the client generic.
- **`APIError`** - one exhaustive error enum every layer maps into, so UI can switch on it.
- **`CredentialProviding`** - a protocol seam the client calls to re-authenticate on 401. C1
  defines it and proves the retry path with a test double; C4/C5 provide the Keychain-backed
  implementation. This keeps the networking layer decoupled from storage and fully unit-testable.
- **`InsecureTrustDelegate`** - `URLSessionDelegate` that skips TLS validation when the server
  is flagged insecure. Constructed from a per-server flag.
- **`AppModel` (@Observable, MainActor)** - root connection state
  (`.disconnected / .connecting / .needsAuth / .connected(FrigateConfig)`), owns the live
  `FrigateClient`, injected into the SwiftUI environment. Views observe it; the root view picks
  ServerSetup vs Login vs the (later) main app. Introduced in C2, referenced here for shape.
- **Storage** - `ServerConfigStore` (non-secret: base URL, allowInsecure, username) in an
  App-Group `UserDefaults` suite; `CredentialStore` (secret: password + cached token) in the
  App-Group Keychain access group. Both land in C4/C6.

**Identifiers to standardize now:** App Group + Keychain access group
`group.com.sagarp.Frigate` (team `LL6476HKHT`). Used by both UserDefaults suite and Keychain.

---

## Chunk map (C1-C6)

Each maps to roadmap bullets in `docs/ROADMAP.md` P1. Each ends at a provable milestone.

- **C1 - Shared API client foundation** (roadmap: "Shared API client" + trust seam). Networking
  layer only; no UI. Milestone: `xcodebuild test` green against mocked responses; can decode a
  real `/api/config`. **Detailed below.**
- **C2 - Server setup screen + connection state** (roadmap: "Server setup screen", "Handle
  http/https", the insecure toggle). URL entry + normalization, "Allow insecure" toggle,
  "Test connection" (probes `GET /api/config`), `AppModel` connection state, root view switch.
  Milestone: type a URL, tap Test, see success/failure; app routes to Login or straight through.
- **C3 - Auth-mode detection + Login** (roadmap: "Detect auth mode", "Login screen", "POST
  /api/login, capture JWT cookie"). Interpret the C2 probe (`200`=off, `401`=on); show the login
  screen when needed; `login(user:password:)` captures the `frigate_token` cookie into the
  client's cookie jar. Milestone: auth-enabled server logs in and reaches connected state;
  auth-disabled server connects with no login.
- **C4 - Keychain credential store (shared App Group)** (roadmap: "Store token/credential in
  Keychain"). Add App Group + keychain-access-group entitlement; `CredentialStore` reads/writes
  the password (and mirrors the current token) under `group.com.sagarp.Frigate` with
  `kSecAttrAccessibleAfterFirstUnlock`. Milestone: password persists in the shared Keychain and
  round-trips; token mirrored for later NSE use.
- **C5 - Silent 401 re-login + retry** (roadmap: "Silent 401 re-login + retry; honor refreshed
  Set-Cookie"). Wire the Keychain-backed `CredentialProviding` into the client's retry seam;
  on 401, re-run `/api/login` with the stored password and retry the original request once;
  rely on the cookie jar to honor refresh `Set-Cookie` during a session. Milestone: force an
  expired/cleared cookie, next request transparently re-auths and succeeds (test-driven).
- **C6 - Persist server config + auto-connect** (roadmap: "Persist server config; auto-connect
  on relaunch"). `ServerConfigStore` in the App-Group UserDefaults suite; on launch, if a server
  + credentials exist, auto-connect (re-login for a fresh cookie) and land in the main app.
  Milestone: relaunch lands connected with nothing re-entered.

_P1 milestone (all chunks): add your Frigate, log in (or connect with auth off), stay logged in
across restarts._

---

## C1 - Shared API client foundation (FULL DETAIL)

Networking layer only, no UI, no Keychain. Everything is unit-testable via an injected
`URLSession` backed by a mock `URLProtocol`. The Keychain/credential seam is defined as a
protocol and exercised with a test double; its real implementation is C4/C5.

### Files to create (under `app/Frigate/`)

**`Networking/HTTPMethod.swift`**
```swift
enum HTTPMethod: String { case get = "GET", post = "POST", put = "PUT", delete = "DELETE" }
```

**`Networking/Endpoint.swift`** - value type for one request.
- Fields: `path: String` (relative to `<baseURL>/api/`, e.g. `"config"`, `"login"`),
  `method: HTTPMethod = .get`, `query: [URLQueryItem] = []`, `body: Data? = nil`,
  `headers: [String: String] = [:]`.
- Static builders: `static var config: Endpoint` (GET `config`);
  `static func login(_ body: LoginRequest) throws -> Endpoint` (POST `login`,
  JSON-encoded body, `Content-Type: application/json`).

**`Networking/APIError.swift`** - exhaustive, `Error`, `Equatable`.
```swift
enum APIError: Error, Equatable {
    case invalidURL
    case transport(URLError)          // network/connection failure
    case unauthorized                 // 401 (after retry seam gives up)
    case authDisabled                 // 404 on /login (auth is off)
    case http(status: Int, body: Data)// other non-2xx
    case decoding(String)             // JSON decode failure (description)
    case notConnected
}
```

**`Networking/CredentialProviding.swift`** - the re-auth seam.
```swift
protocol CredentialProviding: Sendable {
    // Perform a fresh login on `client` using stored credentials. Throws if none/failed.
    func reauthenticate(_ client: FrigateClient) async throws
}
```
C1 ships no concrete conformer (a test double proves the retry path). C5 adds the
Keychain-backed one.

**`Networking/InsecureTrustDelegate.swift`** - `NSObject, URLSessionDelegate, Sendable`.
- Holds `let allowInsecure: Bool`.
- `urlSession(_:didReceive:completionHandler:)`: if `allowInsecure` and the challenge is
  `NSURLAuthenticationMethodServerTrust` with a non-nil `serverTrust`, respond
  `.useCredential` with `URLCredential(trust:)`; otherwise `.performDefaultHandling`.

**`Networking/FrigateClient.swift`** - the actor.
- **Init**:
  `init(baseURL: URL, allowInsecure: Bool = false, credentials: CredentialProviding? = nil, session: URLSession? = nil)`.
  - If `session` is provided (tests), use it. Otherwise build one from
    `URLSessionConfiguration.default` with `httpCookieAcceptPolicy = .always`,
    `httpShouldSetCookies = true`, `httpCookieStorage = HTTPCookieStorage()` (a private jar so
    servers don't cross-contaminate and so the login `Set-Cookie` is captured + auto-refreshed),
    and `delegate = InsecureTrustDelegate(allowInsecure:)` when `allowInsecure`.
  - Store an injectable `JSONDecoder` (explicit `CodingKeys` in models, no global
    key-decoding strategy - safer with Frigate's large config object).
- **Core request builder** (private): compose the URL as
  `baseURL.appending(path: "api").appending(path: endpoint.path)`, apply `query` via
  `URLComponents`, set method, body, `Accept: application/json`, and `endpoint.headers`.
  Throw `.invalidURL` if composition fails.
- **Core send** (private):
  `send(_ endpoint:, allowRetry: Bool) async throws -> (Data, HTTPURLResponse)`.
  1. `try await session.data(for: request)`; map thrown `URLError` -> `.transport`.
  2. Switch on status: `2xx` -> return; `401` -> if `allowRetry`, `credentials != nil`:
     `try await credentials!.reauthenticate(self)` then re-call with `allowRetry: false`; else
     throw `.unauthorized`. `404` on the `login` path -> throw `.authDisabled`. Else ->
     `.http(status:body:)`.
- **Public surface**:
  ```swift
  func send<Response: Decodable>(_ endpoint: Endpoint, as: Response.Type = Response.self) async throws -> Response
  func send(_ endpoint: Endpoint) async throws            // discard body (e.g. login)
  func data(for endpoint: Endpoint) async throws -> Data  // raw bytes (snapshots/clips, P2/P3)
  ```
  Decode failures in the generic `send` -> `.decoding(error.localizedDescription)`.
- **Typed conveniences** (extension):
  ```swift
  func fetchConfig() async throws -> FrigateConfig     // send(.config)
  func login(user: String, password: String) async throws  // send(.login(LoginRequest(...)))
  ```
  `login` maps the `404` to `.authDisabled` so callers can distinguish "auth is off" from
  "bad credentials" (`401`). The captured `frigate_token` cookie lives in the session jar and is
  attached automatically to subsequent requests.

**`Models/FrigateConfig.swift`** - minimal decodable subset for P1.
```swift
struct FrigateConfig: Decodable, Equatable {
    let auth: AuthInfo
    let cameras: [String: CameraConfig]   // only camera names needed in P1; value expands in P2
    struct AuthInfo: Decodable, Equatable {
        let enabled: Bool
        let cookieName: String
        let sessionLength: Int
        let refreshTime: Int
        enum CodingKeys: String, CodingKey {
            case enabled
            case cookieName = "cookie_name"
            case sessionLength = "session_length"
            case refreshTime = "refresh_time"
        }
    }
    struct CameraConfig: Decodable, Equatable {}   // placeholder; unknown keys ignored
}
```

**`Models/LoginRequest.swift`**
```swift
struct LoginRequest: Encodable { let user: String; let password: String }
```

### Test target + tests

- **Add a unit-test target `FrigateTests`** to `app/Frigate.xcodeproj` (none exists today) and
  include it in the shared `Frigate` scheme's test action. This edits `project.pbxproj` and adds
  the group; do it in Xcode (or a careful pbxproj edit) so `xcodebuild test` picks it up.
- **`FrigateTests/MockURLProtocol.swift`** - a `URLProtocol` subclass returning canned
  `(HTTPURLResponse, Data)` set per-test via a static handler; installed on a test
  `URLSessionConfiguration.protocolClasses`. Standard, deterministic, no network.
- **`FrigateTests/EndpointTests.swift`** - URL composition (`baseURL` + `api/` + path + query),
  method, body/headers for `.config` and `.login`.
- **`FrigateTests/FrigateClientTests.swift`**:
  - `fetchConfig` decodes `auth.enabled/cookie_name/session_length/refresh_time` + camera names
    from canned JSON.
  - `401` with no `credentials` -> throws `.unauthorized`.
  - `401` with a stub `CredentialProviding` -> `reauthenticate` called exactly once, request
    retried and succeeds; a second consecutive `401` -> `.unauthorized` (no infinite loop).
  - `login` on `404` -> `.authDisabled`; on `401` -> `.unauthorized`.
  - malformed JSON -> `.decoding`.
  - transport failure (`MockURLProtocol` throws `URLError`) -> `.transport`.

### Concurrency notes

- `FrigateClient` is an `actor`, opting off the project's default `MainActor` isolation - correct
  for networking and required to serialize the re-login/retry. Models are `Sendable` value types;
  `InsecureTrustDelegate` and `CredentialProviding` are `Sendable`.

### Out of scope for C1 (explicit)

No UI, no Keychain, no persistence, no URL-string normalization (C1 takes an already-valid
`URL`; C2 normalizes user input), no concrete `CredentialProviding` (C5).

---

## C2 - Server setup screen + connection state (FULL DETAIL)

First UI. Introduces the root state model and the "add your server" screen. Depends on C1's
`FrigateClient` for the reachability probe. No auth screen yet (C3), no persistence yet (C6).

### Files to create / edit (under `app/Frigate/`)

**`App/AppModel.swift`** - root state, `@Observable`, `@MainActor`.
```swift
@MainActor @Observable final class AppModel {
    enum State {
        case disconnected                                 // show ServerSetup
        case connecting                                   // probing / logging in
        case needsAuth(FrigateClient)                     // reachable, auth on  (filled in C3)
        case connected(FrigateClient, FrigateConfig)      // ready (main app - placeholder for now)
        case failed(String)                               // surfaced back on the setup screen
    }
    private(set) var state: State = .disconnected
    func connect(baseURL: URL, allowInsecure: Bool) async { ... }   // C2 core transition
}
```
Owns the live `FrigateClient` and (once connected) the `FrigateConfig`. Injected into the
SwiftUI environment. C2 implements `.disconnected -> .connecting -> {.connected | .needsAuth |
.failed}`; C3 fleshes out `.needsAuth`; C6 adds launch-time auto-connect.

**`App/RootView.swift`** - switches on `appModel.state`:
`.disconnected/.failed -> ServerSetupView`, `.connecting -> ProgressView`,
`.needsAuth -> LoginView` (C3), `.connected -> MainPlaceholderView` (temporary "Connected" screen
until P2).

**`App/FrigateApp.swift`** (edit) - create the `AppModel`, inject via `.environment`, show
`RootView` instead of the template `ContentView`. (`ContentView.swift` retired/removed.)

**`Networking/ServerURL.swift`** - user-input normalization (pure, unit-testable):
- Trim whitespace, strip trailing slashes.
- If no `scheme://`, prepend `https://` (Frigate's authed proxy port 8971 is TLS).
- Validate via `URLComponents` (non-empty host); return `URL` or throw `.invalidURL`.

**`Features/ServerSetup/ServerSetupModel.swift`** - `@Observable`, `@MainActor` view model:
- Fields: `urlText: String`, `allowInsecure: Bool`, `phase: .idle/.testing/.failed(String)`.
- `testConnection()`:
  1. Normalize `urlText` (`ServerURL`). On failure -> `.failed("Enter a valid address")`.
  2. Build a throwaway `FrigateClient(baseURL:allowInsecure:)`, call `fetchConfig()`.
  3. **Reachability rule** (C2 does not decide auth mode - that's C3): a decoded config (`200`)
     **or** `APIError.unauthorized` (`401`) both mean "this is a reachable Frigate." Either ->
     hand the `baseURL`/`allowInsecure` to `appModel.connect(...)`.
  4. `APIError.transport` -> **auto-fallback**: retry once with `http://` (covers the auth-off
     port 5000 / plain-HTTP LAN case) before giving up; keeps setup seamless per the vision doc.
     Still failing -> `.failed("Couldn't reach a Frigate server there")`.
  5. Other errors -> `.failed(<mapped message>)`.

**`Features/ServerSetup/ServerSetupView.swift`** - form: URL field (URL keyboard, no
autocaps/autocorrect), "Allow insecure connections (self-signed)" toggle, "Connect" button
(spinner while `.testing`), inline error text on `.failed`.

### Tests (`FrigateTests`)
- `ServerURL` normalization: bare host, host:port, with/without scheme, trailing slash, junk.
- `ServerSetupModel` with an injected mock-session client (reuse C1 `MockURLProtocol`): `200` ->
  connect; `401` -> connect (reachable); `transport` then http `200` -> fallback connect;
  hard transport -> `.failed`.

### Milestone
Type a URL, toggle insecure if needed, tap Connect: reachable server routes onward (to `.needsAuth`
or `.connected`), unreachable shows a clear error. No persistence yet.

---

## C3 - Auth-mode detection + Login (FULL DETAIL)

Decide auth-on vs auth-off from the probe, and log in when needed. `POST /api/login`'s
`Set-Cookie` (`frigate_token`) is captured automatically by C1's cookie jar.

### Files to create / edit
**`App/AppModel.swift`** (edit) - finish the flow:
- In `connect(...)`, interpret the probe by **HTTP status, not `auth.enabled`** (you can only read
  `config.auth.enabled` once already authorized): a decoded config (`200`) -> `.connected`;
  `APIError.unauthorized` (`401`) -> `.needsAuth(client)` (keep the same client so its cookie jar
  persists into login).
- Add `submitLogin(user:password:) async` used by the login screen: calls
  `client.login(...)`, then re-probes `fetchConfig()` -> `.connected`.

**`Features/Login/LoginModel.swift`** - `@Observable`, `@MainActor`:
- Fields: `username`, `password`, `phase: .idle/.submitting/.failed(String)`.
- `submit()` -> `appModel.submitLogin(...)`. Error mapping:
  `.unauthorized` (`401`) -> `.failed("Incorrect username or password")`;
  `.authDisabled` (`404`, edge: auth turned off between probe and submit) -> just re-probe ->
  `.connected`; `.transport` -> `.failed("Connection lost")`.

**`Features/Login/LoginView.swift`** - username + secure password fields, Sign In button
(spinner on `.submitting`), inline error, host label for context.

### Tests (`FrigateTests`)
- `AppModel.connect`: `200` -> `.connected`; `401` -> `.needsAuth`.
- `submitLogin`: mock login `200` then config `200` -> `.connected`; login `401` -> error surfaced,
  stays `.needsAuth`; `404` -> `.connected`.

### Milestone
Auth-enabled server presents the login screen and, on correct credentials, reaches `.connected`;
auth-disabled server reaches `.connected` with no login screen. (Credentials not yet persisted.)

---

## C4 - Keychain credential store, shared App Group (FULL DETAIL)

Add the entitlements and a Keychain wrapper so the password (and current token) live in a shared
access group the app and the future Notification Service Extension can both read (per CLAUDE.md).
No behavior change yet - C5/C6 consume it.

### Files to create / edit
**`app/Frigate/Frigate.entitlements`** (new) -
`com.apple.security.application-groups = [group.com.sagarp.Frigate]` and
`keychain-access-groups = [$(AppIdentifierPrefix)group.com.sagarp.Frigate]`.

**`app/Frigate.xcodeproj/project.pbxproj`** (edit) - set `CODE_SIGN_ENTITLEMENTS =
Frigate/Frigate.entitlements` for the app target; enable the App Groups + Keychain Sharing
capabilities. **Possible manual step:** the `group.com.sagarp.Frigate` App Group may need to be
registered/toggled in Xcode's Signing & Capabilities (team `LL6476HKHT`, automatic signing);
flag if provisioning errors appear.

**`Storage/CredentialStoring.swift`** - protocol seam so logic is testable off-device:
```swift
protocol CredentialStoring: Sendable {
    func savePassword(_ p: String, account: String) throws
    func password(account: String) throws -> String?
    func saveToken(_ t: String) throws
    func token() throws -> String?
    func clear() throws
}
```

**`Storage/KeychainCredentialStore.swift`** - `SecItem` implementation:
- `kSecClass = kSecClassGenericPassword`, `kSecAttrService = "com.sagarp.Frigate"`,
  `kSecAttrAccount = <baseURL>|<username>`, `kSecAttrAccessGroup =
  "<prefix>group.com.sagarp.Frigate"`,
  `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (readable by the NSE
  after first unlock; not synced to iCloud).
- Upsert via `SecItemAdd` / `SecItemUpdate`; map `OSStatus` to a `KeychainError`.

### Tests
- Logic/among-fields tests use an in-memory `CredentialStoring` double.
- `KeychainCredentialStore` round-trip (save/read/clear) runs in the simulator/on-device with the
  host app's entitlement - not pure-unit (needs the access group).

### Milestone
Password saves to and round-trips from the shared Keychain access group; token mirror slot works.

---

## C5 - Silent 401 re-login + retry (FULL DETAIL)

Supply the concrete `CredentialProviding` (defined in C1) and confirm the transparent re-auth
end to end. "Honor refreshed `Set-Cookie`" comes free from the cookie jar; we mirror the refreshed
token to the store for the NSE.

### Files to create / edit
**`Networking/KeychainCredentialProvider.swift`** - conforms to C1's `CredentialProviding`,
holds a `CredentialStoring` + the account key:
- `reauthenticate(_ client:)`: read `password(account:)`; if present, `try await
  client.login(user:password:)`; if absent, throw (client then surfaces `.unauthorized` -> app
  routes to Login).

**`Networking/FrigateClient.swift`** (edit) - two small additions on top of C1's seam:
- After any successful (2xx) response, if the cookie jar's `frigate_token` value changed
  (server refresh within `refresh_time`), call the store's `saveToken(_:)` so the shared store
  stays current (keeps the NSE's snapshot fetch working in P5).
- Construction wires the `KeychainCredentialProvider` as `credentials` (via `AppModel`).

### Tests (`FrigateTests`)
- `MockURLProtocol` sequence `401` then `200` + stubbed provider -> `reauthenticate` called once,
  original request retried and succeeds; a second `401` -> `.unauthorized` (no loop).
- When a `200` carries a changed `Set-Cookie`, `saveToken` is invoked with the new value.

### Milestone
Force an expired/cleared cookie; the next request silently re-logs-in with the stored password and
succeeds, with no user interaction.

---

## C6 - Persist server config + auto-connect on relaunch (FULL DETAIL)

Remember the server and reconnect automatically at launch, closing the P1 loop.

### Files to create / edit
**`Models/ServerConfig.swift`** - `Codable` non-secret record: `baseURL: URL`,
`allowInsecure: Bool`, `username: String?`.

**`Storage/ServerConfigStore.swift`** - persists `ServerConfig` as JSON in
`UserDefaults(suiteName: "group.com.sagarp.Frigate")` (App-Group suite, shareable with the NSE).
`load()`, `save(_:)`, `clear()`.

**`App/AppModel.swift`** (edit) -
- `bootstrap()` at launch: `ServerConfigStore.load()`. If a config + a stored password exist ->
  `.connecting`, build the client with the `KeychainCredentialProvider`, and **re-login for a
  fresh cookie** (the in-memory cookie jar does not survive relaunch), then `fetchConfig()` ->
  `.connected`. If re-login fails (creds changed) -> `.needsAuth`. If nothing stored ->
  `.disconnected`.
- On successful setup/login (C2/C3), persist `ServerConfig` (store) and the password
  (`CredentialStore`).
- `logout()`: clear cookie jar + `CredentialStore` + `ServerConfigStore` -> `.disconnected`.

**`App/FrigateApp.swift`** (edit) - call `appModel.bootstrap()` on appear.

### Tests
- `ServerConfigStore` round-trip against a temp suite name.
- `AppModel.bootstrap` with doubles: stored config+creds -> `.connected`; stored config, failed
  re-login -> `.needsAuth`; nothing stored -> `.disconnected`.

### Milestone
Kill and relaunch: the app auto-connects and lands in `.connected` (or the login screen if creds
went stale) with nothing re-entered. **Completes the P1 milestone.**

---

## Verification

**C1 (this chunk):**
- Unit tests, no server needed:
  ```bash
  xcodebuild -project "app/Frigate.xcodeproj" -scheme Frigate \
    -destination 'platform=iOS Simulator,name=iPhone 17' test
  ```
  Expect `FrigateTests` to run and pass (Endpoint building, decode, 401/404 mapping, retry seam).
- Optional live smoke (manual, needs a reachable Frigate): from a scratch test or temporary
  debug call, construct `FrigateClient(baseURL:)` and print `fetchConfig()` /
  `login(user:password:)` results against a real server to confirm real-world decode and the
  `frigate_token` cookie capture.

**P1 end-to-end (after C6):** on a physical device - add a Frigate URL, connection test passes;
auth-enabled server shows login and signs in, auth-disabled connects directly; force-expire the
session and watch a request silently re-auth; kill and relaunch the app and land connected with
nothing re-entered.

## Docs to update as we go

- `docs/DECISIONS.md` (currently empty): record the cookie-session-with-stored-password choice,
  the insecure-toggle choice, and the `FrigateClient`/`Endpoint`/`CredentialProviding` seam.
- `docs/ROADMAP.md`: flip P1 items to in-progress/done as each chunk lands.
- `docs/LEARNINGS.md`: capture gotchas (App Group entitlement/provisioning, cookie-jar refresh
  behavior) as they surface.
