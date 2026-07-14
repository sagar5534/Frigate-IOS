# Decisions (ADRs)

Short architecture decision records: the choice, why, and consequences. Newest first.

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
