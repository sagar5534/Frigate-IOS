# Decisions (ADRs)

Short architecture decision records: the choice, why, and consequences. Newest first.

## ADR-008 - Single probe: `AppModel.connect` owns reachability + http fallback

**Context:** Through C2-C6 the reachability check ran twice per Connect - once in
`ServerSetupModel` (to decide https vs http) and again in `AppModel.connect` (to produce the state).
Now that `AppModel` persists the working `baseURL` (C6), the split no longer buys anything.

**Decision:** Fold the probe + one-shot http:// fallback into **`AppModel.connect`**, which now
`throws APIError` on failure and only mutates `state` on success (`.connected`/`.needsAuth`).
`ServerSetupModel` shrinks to *normalize the URL -> call `connect` -> map a thrown error to a
message*; it no longer needs an injected `URLSession`. Because `connect` leaves `state` untouched on
failure (it does **not** flip to `.connecting`), the setup screen stays mounted and the typed input
is preserved while the error shows - previously guaranteed only by never navigating away during the
`ServerSetupModel` probe. The now-unused `.failed` state and `AppModel.message(for:)` were removed;
setup errors live in `ServerSetupModel.phase`.

**Consequences:** One `/api/config` round-trip per attempt instead of two; the fallback logic lives
in one place; `ServerSetupModel` is a thin normalizer. Supersedes the split-probe part of ADR-003.

## ADR-007 - Persistence + launch auto-connect owned by `AppModel`

**Context:** C6 must remember the server and reconnect at launch. The in-memory cookie jar dies with
the process, and there is no refresh token, so a fresh cookie means re-running `/api/login`.

**Decision:**
- **`ServerConfig`** (non-secret: `baseURL`, `allowInsecure`, `username?`) is persisted as JSON in
  the **App-Group `UserDefaults` suite** (`ServerConfigStore`), shareable with the NSE later. The
  password stays in the Keychain (C4); the two are keyed together by `CredentialAccount.key`.
- **`AppModel` owns the lifecycle:** `connect` (auth off) and `submitLogin` (auth on) persist
  config (+ password) only on success; `bootstrap()` at launch loads the config and, if a username
  + stored password exist, **re-logs-in for a fresh cookie** then probes -> `.connected`; stale or
  missing creds -> `.needsAuth`; nothing saved -> `.disconnected`. `logout()` drops the client
  (killing its cookie jar) and clears both stores.
- **Clients are built through one `makeClient(username:)` helper** that wires the
  `KeychainCredentialProvider` (when a username is known) + the token-mirror store, so every live
  client can silently re-auth. Stores are injectable so bootstrap/persist/logout are unit-tested
  with an in-memory Keychain double and a temp `UserDefaults` suite.

**Consequences:** Relaunch lands connected with nothing re-entered; the login screen only reappears
when credentials genuinely went stale. `submitLogin` now builds a fresh client (rather than reusing
the probe client) so the connected client carries the credential provider - the probe's empty
cookie jar was nothing to preserve.

## ADR-006 - Silent re-login: provider drives it, login path is exempt from retry

**Context:** C5 makes expired sessions self-heal. The client's C1 retry seam calls
`CredentialProviding.reauthenticate` on a `401`; the concrete provider re-runs `/api/login`.

**Decision:**
- **`KeychainCredentialProvider`** reads the stored password for `<baseURL>|<username>` and calls
  `client.login`; no stored password -> throws `.unauthorized` so the app routes to Login.
- **The login request itself is exempt from the retry seam** (`endpoint.path != "login"` guard in
  the client). Without it, a bad stored password would recurse forever (`login` 401 ->
  reauthenticate -> `login` 401 -> ...). A latent C1 bug that only bites once a real provider is
  attached; now bounded to a single login attempt.
- **Refreshed token mirroring:** on any `2xx` carrying a `frigate_token` `Set-Cookie`, the client
  mirrors the value into the store via an injected `credentialStore`. Reading the response header
  (rather than diffing the cookie jar) is deterministic and matches the server's "only sends
  `Set-Cookie` on issue/refresh" behaviour.

**Consequences:** Expired/cleared cookies re-auth transparently with no UI; the NSE's token mirror
stays current for P5. No infinite loops on bad credentials.

## ADR-005 - Keychain sharing via the App Group as the access group (no team prefix)

**Context:** The password (and a token mirror) must live in a Keychain access group both the app and
the future Notification Service Extension can read. The plan sketched
`$(AppIdentifierPrefix)group.com.sagarp.Frigate` for the entitlement.

**Decision:** Use the **App Group id `group.com.sagarp.Frigate` directly as the `keychain-access-groups`
entry**, with **no `$(AppIdentifierPrefix)` team prefix**. App groups are the one kind of keychain
access group iOS does not prefix with the team id, so `kSecAttrAccessGroup = "group.com.sagarp.Frigate"`
at runtime needs no hardcoded team id and one identifier serves both the Keychain and the
App-Group `UserDefaults` suite (C6). Items use
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (readable by the NSE while locked; never
iCloud-synced). Passwords are keyed by account `<baseURL>|<username>`; the token is a single
reserved-account mirror slot. `KeychainCredentialStore` sits behind the `CredentialStoring`
protocol so credential logic is testable with an in-memory double.

**Consequences:** No team id baked into source; verified working on the simulator (real
`SecItem` round-trip against the shared group signs and passes). Deviates from the plan's literal
`$(AppIdentifierPrefix)` text - see `LEARNINGS.md`.

## ADR-004 - Login reuses the probe's client; `submitLogin` owns the re-probe

**Context:** C3 needs to log in when the C2 probe returned `401` and land in `.connected`. The
JWT arrives only as a `Set-Cookie` (`frigate_token`), so login and the follow-up config fetch must
share one cookie jar.

**Decision:**
- **`.needsAuth` carries the same `FrigateClient`** built during the probe, and
  `AppModel.submitLogin` logs in on *that* client so its cookie jar captures `frigate_token` and
  attaches it to the re-probe automatically.
- **`submitLogin` owns the flow:** `login(...)` -> re-`fetchConfig()` -> `.connected`. A `404`
  (`.authDisabled`, auth turned off between probe and submit) is swallowed and the unauthenticated
  re-probe proceeds. It throws `APIError` on failure so `LoginModel` maps it to a message
  (`401` -> "Incorrect username or password", `.transport` -> "Connection lost"); state stays
  `.needsAuth` so the user can retry.
- **`AppModel.baseURL`** is stored on connect, surfaced as the login screen's host label and reused
  for persistence in C6.

**Consequences:** No cookie plumbing at the call site; the session jar does it. Bad credentials
keep the login screen up with a clear error rather than bouncing to setup.

## ADR-003 - Connection state in `AppModel`; reachability decided by HTTP status

> Partly superseded by **ADR-008**: the two-probe split (setup model probes, then `connect`
> re-probes) was collapsed into a single `AppModel.connect`, and the `.failed` state was removed.
> The core decisions below - `AppModel` as the state owner and reachability-by-HTTP-status - stand.

**Context:** C2 needs a root state the SwiftUI tree switches on (setup vs login vs main app) and a
"Test connection" that works before we know whether auth is on. Auth mode can't be read from
`config.auth.enabled` until we're already authorized.

**Decision:**
- **`AppModel` (`@MainActor @Observable`)** owns a `State` enum
  (`disconnected / connecting / needsAuth(client) / connected(client, config) / failed(msg)`),
  the live `FrigateClient`, and the `connect(baseURL:allowInsecure:)` transition. Injected into the
  environment; `RootView` switches on it.
- **Reachability is decided by HTTP status, not `auth.enabled`:** a decoded config (`200`) ->
  `.connected`; `APIError.unauthorized` (`401`) -> `.needsAuth` (both prove a reachable Frigate);
  anything else -> `.failed`. C3 fills in `.needsAuth` (login).
- **`ServerSetupModel` owns input normalization + the reachability probe**, including a one-shot
  **http:// auto-fallback** on transport failure (covers the auth-off port 5000 / plain-HTTP LAN
  case), then hands the *working* base URL to `AppModel.connect`. Keeping the fallback here means
  the URL that actually reached the server is the one persisted later (C6).
- **Testability:** both models take an optional injected `URLSession`, so the probe/transition run
  against C1's `MockURLProtocol` with no network or server.

**Consequences:** The setup screen can validate reachability before auth is known; the same
`FrigateClient` (and its cookie jar) created during the probe carries into `.needsAuth`/login (C3).

## ADR-002 - Shared API client seams: `FrigateClient` / `Endpoint` / `CredentialProviding`

**Context:** Every P1+ feature (cameras, events, live negotiation) talks to Frigate's HTTP API.
We need one reusable, testable networking layer rather than scattered `URLSession` calls.

**Decision:**
- **`FrigateClient` is an `actor`** and the single entry point for every Frigate HTTP call.
  Feature code never touches `URLSession`; it calls typed methods (`fetchConfig()`,
  `login(...)`) or builds an `Endpoint` and calls the generic `send(_:)`. Actor isolation
  serializes the `401 -> re-login -> retry` dance without races.
- **`Endpoint`** is a value type describing one request (path/method/query/body/headers). Adding
  an API = one `Endpoint` builder + one `Codable` model.
- **`APIError`** is one exhaustive `Equatable` enum every layer maps into, so UI can switch on it.
- **`CredentialProviding`** is a protocol seam the client calls to re-authenticate on `401`. C1
  defines it and proves the retry path with a test double; the Keychain-backed conformer lands in
  C5. Keeps networking decoupled from storage and fully unit-testable.

**Consequences:** Networking is unit-testable with an injected `URLSession` + mock `URLProtocol`
(no server needed). Retry is bounded to a single attempt (no infinite loop on repeated `401`).

## ADR-001 - Cookie session with a stored password; per-server insecure toggle

**Context (verified against `~/Documents/frigate`):** `POST /api/login` returns an empty `200`
with the JWT delivered **only** as a `Set-Cookie` (`frigate_token`); auth-disabled returns `404`.
The server auto-refreshes the cookie on requests near expiry **only when the token arrives as a
cookie**, and there is **no long-lived API key / refresh token** - once a JWT fully expires the
only way back is another `POST /api/login`.

**Decision:**
- **Cookie-based auth.** The client keeps a private `HTTPCookieStorage` jar per server, so the
  login `Set-Cookie` is captured and the server's refresh is honored for free within a session.
- **Store the password** (C4, shared App-Group Keychain) so the app - and later the Notification
  Service Extension - can silently re-login on `401`/expiry and stay logged in indefinitely.
- **Self-signed certs** = a simple per-server **"Allow insecure connections" toggle**
  (`InsecureTrustDelegate` skips TLS validation for that host). No cert-pinning UI.

**Consequences:** No token-refresh endpoint to manage; the cookie jar does the work in-session,
the stored password covers full expiry and cold launch (the in-memory jar doesn't survive
relaunch, so bootstrap re-logs-in for a fresh cookie - C6).
