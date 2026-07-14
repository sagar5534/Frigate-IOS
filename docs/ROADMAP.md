# Roadmap

The living task tracker. Work happens here: phases break down into small tasks, done one by
one. Claude keeps statuses current as work proceeds - marking tasks in progress / done /
blocked only when they actually change, no filler.

## Status convention

- `- [ ]` not started
- `- [ ]` ... `(in progress)` - actively being worked
- `- [x]` done
- `- [ ]` ... `(blocked: reason)` - waiting on something

Each phase ends at a **provable milestone** - something you can point at and say "this works."

## Focus order

**App first - get a user able to actually use it. Notifications come later.** The scariest
technical risk (push plumbing) is deferred in favor of shipping something usable: connect, log
in, see cameras, browse events, watch video. The reordering is deliberate; see
`docs/DECISIONS.md` if revisiting.

---

## P0 - Scaffolding & decisions
- [x] Repo, git, `.gitignore`, license
- [x] SwiftUI app builds from template
- [x] Core planning docs (VISION done; DECISIONS and LEARNINGS are living docs, filled in as decisions/gotchas actually arise)
- [x] Apple Developer account (paid team `LL6476HKHT`, signing + provisioning already working)
- [x] Build & run on a physical device

_Milestone: project builds and runs on a device; docs establish the plan._

## P1 - Connect & authenticate
Foundation everything else builds on.
- [x] Shared API client (base URL, JSON decoding, cookie/JWT handling, error handling) - C1: `FrigateClient` actor + `Endpoint`/`APIError`/`CredentialProviding`/`InsecureTrustDelegate`; `FrigateTests` green (10 tests)
- [x] Server setup screen: enter Frigate URL + connection test - C2: `ServerSetupView`/`ServerSetupModel`, `AppModel` state machine, `RootView` switch, `MainPlaceholderView`
- [x] Handle http/https and self-signed certs (explicit trust) - C2: `ServerURL` normalization (default https), http:// auto-fallback, "Allow insecure" toggle wired to `InsecureTrustDelegate`
- [x] Detect auth mode - support both auth-enabled and auth-disabled Frigate - C3: probe status decides (200 -> connected, 401 -> needsAuth); auth-off connects with no login
- [x] Login screen (username / password) - C3: `LoginView`/`LoginModel`, `RootView` shows it on `.needsAuth`, host label for context
- [x] `POST /api/login`, capture JWT cookie - C3: `AppModel.submitLogin` logs in on the reused client (cookie jar captures `frigate_token`), then re-probes to `.connected`
- [x] Store token/credential in Keychain (shared App Group access group) - C4: `Frigate.entitlements` (App Group + keychain sharing), `CredentialStoring`/`KeychainCredentialStore`; password + token-mirror round-trip against `group.com.sagarp.Frigate`
- [x] Silent 401 re-login + retry; honor refreshed `Set-Cookie` - C5: `KeychainCredentialProvider` wired into the client; `401` re-runs `/api/login` with the stored password and retries once; refreshed `frigate_token` mirrored to the store
- [x] Persist server config; auto-connect on relaunch - C6: `ServerConfig`/`ServerConfigStore` (App-Group defaults); `AppModel.bootstrap()` re-logs-in for a fresh cookie on launch; `logout()` clears everything

_Milestone: add your Frigate, log in (or connect with auth off), stay logged in across restarts._
_Status: implemented and unit-tested (51 tests); end-to-end against a real Frigate server still to be run on-device._

## P2 - Camera grid
- [ ] App shell / navigation (Cameras, Events)
- [ ] Fetch `/api/config`, parse camera list
- [ ] Camera grid of snapshot tiles
- [ ] Auto-refresh snapshots every few seconds
- [ ] Tap camera to open a larger snapshot / detail view
- [ ] Minimal Settings: server info, connection status, log out

_Milestone: see all your cameras, updating._

## P3 - Events timeline
- [ ] Fetch event/review list with thumbnails
- [ ] Filters (camera, label, time range)
- [ ] Event detail screen (snapshot)
- [ ] Clip playback via AVPlayer (mp4 - the easy video)
- [ ] Pagination / infinite scroll

_Milestone: browse events and play their clips._

## P4 - Live video
- [ ] Define the `LivePlayer` interface
- [ ] `HLSPlayer` implementation (AVPlayer + HLS)
- [ ] Single-camera fullscreen live view
- [ ] Wire live view into the camera detail screen
- [ ] Reconnect / clean teardown handling

_Milestone: watch a live camera._

---

## P5 - Notifications
Notifier sidecar + relay + push registration; rich notifications with snapshot.
_Milestone: a Frigate event produces a notification with image on a real iPhone._

## P6 - Seamless onboarding
QR pairing, mDNS discovery, in-app config synced to the notifier.
_Milestone: set the whole thing up in ~3 taps, no YAML._

## P7 - Packaging
HA add-on + Docker for the notifier; bring-your-own-push escape hatch.
_Milestone: a new user installs from a documented, supported path._

## P8 - Parity extras
Recordings timeline, PTZ, two-way audio, quiet hours, WebRTC low-latency live, full settings.
_Milestone: feature parity with the PWA._

---

## To verify against a real Frigate (as we build P1-P3)
- JWT cookie name and refresh behavior (`session_length` / `refresh_time`)
- Whether Frigate has long-lived API keys / personal access tokens to store instead of a password
- Exact snapshot / clip URL shapes and the events vs reviews endpoints
