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
_Status: implemented and unit-tested (51 tests); verified end-to-end against a real Frigate server
(LAN, plain-HTTP auth proxy) in the iPhone 17 simulator. Found and fixed two bugs surfaced only by
that live run: default ATS silently blocked the plain-HTTP LAN connection (see LEARNINGS.md), and
the private cookie jar (`HTTPCookieStorage()`) never actually captured the login `Set-Cookie`, so
every post-login request 401'd (see LEARNINGS.md). Sign-in now works end-to-end._

## P2 - Camera grid
- [x] App shell / navigation (Cameras, Events) - `MainTabView` (Cameras/Events/Settings tabs) replaces the P1 `MainPlaceholderView`
- [x] Fetch `/api/config`, parse camera list - `FrigateConfig.CameraConfig.enabled` + `enabledCameraNames`; verified field shapes against a real server (frigate.sagarp.ca)
- [x] Camera list of snapshot rows - `CameraListView`/`CameraGridModel`, `GET /api/{camera}/latest.jpg?height=N`. Reworked from a grid to a full-width, free-scrolling list (one camera per row) with a bottom-right "x ago"/"Now" freshness badge (`SnapshotAgeBadge`), Apple Home-style
- [x] Auto-refresh snapshots every few seconds - `CameraGridModel.startAutoRefresh()` (5s loop, cancelled on disappear)
- [x] Tap camera to open a larger snapshot / detail view - `CameraDetailView`/`CameraDetailModel` (720p, own refresh loop)
- [x] Minimal Settings: server info, connection status, log out - `SettingsView`

_Milestone: see all your cameras, updating._
_Status: implemented and unit-tested (64 tests); verified real `/api/config` and snapshot shapes
against a live server via curl. End-to-end tap-through (login -> grid rendering) on-device/simulator
still needs a human pass - no UI automation was available in this session (see DECISIONS.md/session
notes if that becomes a recurring need)._

## P3 - Events timeline
- [x] Fetch event/review list with thumbnails - C1: `ReviewSegment` model + `FrigateClient` review/thumbnail/clip-URL support; C2: `EventsView`/`EventsModel`/`ReviewCardView`/`ReviewThumbnail` (day-grouped list, loading/empty/error states, pull-to-refresh)
- [x] Filters (camera, label, time range) - C3: `EventFilters`/`EventFilterSheet`, `EventsModel.filters` wired into the query via `.task(id:)` with a cancellation guard against stale results
- [x] Event detail screen (snapshot) - C4: `ReviewDetailView`/`ReviewDetailModel` (metadata, mark reviewed/unreviewed via `POST /api/reviews/viewed`, propagated back into the list)
- [x] Clip playback via AVPlayer - C5: `ClipPlayerView` plays the HLS VOD manifest (not `clip.mp4` - see DECISIONS.md), cookie-authed via `AVURLAssetHTTPCookiesKey`. **Not yet smoke-tested on a physical device/real server** (no device available this session) - do that before considering P3 fully done.
- [x] Pagination / infinite scroll - C6: `EventsModel.loadMore()` pages older activity as the last row scrolls into view, moving `before`/`after` together each page, de-duping by id, guarding against filter-change races

_Milestone: browse events and play their clips._
_Status: implemented and unit-tested (105 tests, up from 64 at the end of P2); each chunk (C1-C6)
went through an independent review pass with fixes applied where findings landed (silent
mark-reviewed failures now surface an error; a filter-change race in pagination is guarded; a
pagination test that passed without exercising its own logic was corrected). **One thing this
session could not verify: clip playback (C5) has not been smoke-tested on a physical device or
against a real server** - the HLS-over-mp4 choice and the cookie-auth reasoning are sound on
paper (see DECISIONS.md ADR-011) but unconfirmed end-to-end. Do that pass before treating P3 as
fully done; also worth a real-server check of whether `/api/review` timestamps are numeric (as
assumed) or ever ISO strings, since the response model's `datetime` type annotation is a soft
signal a real server hasn't disproven._

## Recent Activity strip (P8 parity, pulled forward)
- [x] Horizontal strip of looping preview clips above the camera list, mirroring the row Frigate's
  own PWA puts atop its live dashboard - `Features/RecentActivity/` (`RecentActivityModel`,
  `RecentActivityStrip`, `RecentActivityCard`, `LoopingVideoPlayer`), slotted into
  `CameraListView`. Same query as the PWA (`severity=alert&reviewed=0&limit=10` + a client-side
  "started within the last hour" cut, which the server has no parameter for); 30s poll in place of
  the PWA's websocket. Video comes from `GET /api/review/{id}/preview?format=mp4` for every card -
  the server has already time-compressed it ~8.33x, so it plays at rate 1.0 and needs none of the
  seek-into-the-hourly-preview-at-8x machinery the PWA uses for older segments.
- Camera scoping: the PWA's `alertCameras` scopes to the selected camera group. We have one
  Cameras page, so the strip takes `config.enabledCameraNames` - the cameras the screen itself
  shows. That parameter is the seam for camera groups when they land.
- _Verified end-to-end against the live server (frigate.sagarp.ca) in the simulator: cards render
  and loop, scrolling snaps with no black cards, tap pushes `ReviewDetailView`, marking reviewed
  removes the card, and the empty state leaves no gap above the camera list._

## P4 - Live video (WebRTC)
Frigate exposes **no live HLS** - the original `HLSPlayer` plan is void (ADR-012). Live view is a
three-tier ladder built as three separate phases; P4 is the top rung only. Plan:
`docs/plans/P4-live-video.md`.
- [x] C1 - `LivePlayer` seam + live source resolution - `LiveTransport`/`LiveStreamSource.ladder`,
  `FrigateConfig.go2rtc` + `CameraConfig.live`, `LivePlayer`/`LivePlayerState`/`LivePlayerError`/
  `LivePlayerFactory`, `SignalingChannel` + `LiveSocket`, `Endpoint.webrtcWebSocket`,
  `FrigateClient.webSocketURL`/`webSocketRequest`/`liveSocket`. 145 tests green (was 126).
  Found that `JSONDecoder`'s `allKeys` is hash order, so stream resolution can't use position -
  see `LEARNINGS.md` and the plan's C1 ordering finding
- [x] C2 - go2rtc signaling - `SignalingMessage` codec + `WebRTCSignaling` (buffers candidates that
  arrive before the answer, since `RTCPeerConnection.add(_:)` rejects those), tested against
  `FakeSignalingChannel`. 157 tests (2 skipped).
  **Gate still open:** `LiveServerIntegrationTests` proves the socket opens through nginx
  `auth_request` with the session cookie and is refused without it, but it is opt-in (needs
  `FRIGATE_TEST_URL`/`_USER`/`_PASSWORD`) and has not been run against the real server yet.
  Run it before starting C3 - it is what justifies adding the libwebrtc binary
- [ ] C3 - WebRTC dependency (`stasel/WebRTC`, pinned) + `WebRTCLivePlayer` + `LiveVideoView`
- [ ] C4 - Wire into camera detail: snapshot until first frame, fullscreen, connecting/stalled/
  failed states, snapshot poll stops once live is playing
- [ ] C5 - Reconnect, teardown, and an actionable `iceFailed` message (no fallback tier exists yet)

_Milestone: open a camera and watch it live, recovering after a network blip._

## P4.1 - Live video: MSE tier
Demand-driven, not scheduled. Real H.264 at ~1-2s over the **same authenticated HTTPS origin**, so
it reaches users behind Cloudflare Tunnel and other setups WebRTC's port-8555 media path cannot
cross. Hand-written fMP4 demuxer into `AVSampleBufferDisplayLayer` (~400-600 lines); no library
exists that consumes a live fMP4 byte stream (surveyed in ADR-012). Slots in as one `LivePlayer`
conformer plus one case in `LivePlayerFactory`.
- [ ] `MSELivePlayer` behind the existing seam
- [ ] Automatic escalation down the ladder when the tier above fails

_Milestone: a user whose network blocks WebRTC still gets real video._

## P4.2 - Live video: MJPEG tier
The floor: `multipart/x-mixed-replace` off the existing `FrigateClient` path. No ports, no YAML, no
go2rtc. Also the **only** option for cameras with no restream configured, so this tier is what
makes live view work for every camera rather than most.
- [ ] `MJPEGLivePlayer` behind the existing seam
- [ ] Non-restreamed cameras resolve to this tier automatically

_Milestone: every camera shows motion, on every network._

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
Recordings timeline, PTZ, two-way audio, quiet hours, full settings.
_Milestone: feature parity with the PWA._

---

## To verify against a real Frigate (as we build P1-P3)
- JWT cookie name and refresh behavior (`session_length` / `refresh_time`)
- Whether Frigate has long-lived API keys / personal access tokens to store instead of a password
- Exact snapshot / clip URL shapes and the events vs reviews endpoints
- **P3, not yet done:** clip playback (`ClipPlayerView`'s HLS VOD manifest) on a physical device -
  does the manifest load and do segments actually play through, confirming cookie auth covers the
  whole HLS request chain, not just the initial fetch
- **P3, not yet done:** whether `/api/review`'s `start_time`/`end_time` come back numeric (assumed
  throughout `ReviewSegment`) or ever as ISO strings on some server/version
- **P4:** whether the `frigate_token` cookie really rides the WebSocket handshake through nginx's
  `auth_request` on `/live/webrtc/api/ws` (C2 proves this before any WebRTC code exists)
- **P4:** whether go2rtc's advertised ICE candidates are reachable from cellular and from LAN on
  the real server, and what the app-size hit of the libwebrtc xcframework actually is
