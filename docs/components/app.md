# App internals

How the SwiftUI app (`app/Frigate/`) is put together. See `../ROADMAP.md` for what's built vs.
pending and `../DECISIONS.md` for why things are shaped this way.

## Flow: `AppModel` state machine

`App/AppModel.swift` is the root of the app: a `@MainActor @Observable` class owning a `State`
enum (`disconnected` / `connecting` / `needsAuth(FrigateClient)` /
`connected(FrigateClient, FrigateConfig)`). `RootView` switches on it to pick the top-level screen:

- `.disconnected` -> `ServerSetupView` (enter a Frigate URL)
- `.connecting` -> a spinner (launch-time auto-reconnect)
- `.needsAuth` -> `LoginView`
- `.connected` -> `MainTabView` (the P2 main app shell)

`AppModel.bootstrap()` runs once at launch (`FrigateApp.swift`'s `.task`), reconnecting to a saved
`ServerConfig` if there is one. `connect(baseURL:allowInsecure:)` and `submitLogin(user:password:)`
drive the setup/login screens; `logout()` clears everything and returns to `.disconnected`.

## Networking: `FrigateClient`

`Networking/FrigateClient.swift` is an `actor` and the single place that talks to a Frigate server.
Feature code never touches `URLSession` directly - it calls typed methods (`fetchConfig()`,
`login(user:password:)`, `snapshot(camera:height:)`) or builds an `Endpoint`
(`Networking/Endpoint.swift`) and calls `send(_:)` / `data(for:)`. The client owns a private
cookie-jar `URLSession` per connected server, handles the `401 -> re-login (via
CredentialProviding) -> retry once` dance, and mirrors a refreshed `frigate_token` cookie into
`CredentialStoring` so the (future) Notification Service Extension can read it too.

Errors are a single `APIError` enum so UI can exhaustively switch on failure modes
(`.unauthorized`, `.authDisabled`, `.transport`, `.decoding`, `.http`, ...).

## Storage

- `Storage/KeychainCredentialStore.swift` - passwords + the current JWT mirror, in a shared App
  Group Keychain access group (`group.com.sagarp.Frigate`) so the future Notification Service
  Extension process can read the token too. `CredentialStoring` is the protocol seam;
  `FrigateTests` swaps in an in-memory double.
- `Storage/ServerConfigStore.swift` - the non-secret `ServerConfig` (base URL, `allowInsecure`,
  username), persisted in the App Group `UserDefaults` suite so `bootstrap()` can auto-connect.

## Models

`Models/FrigateConfig.swift` decodes a deliberately small subset of the real `/api/config` payload
(which has dozens of top-level keys - detectors, ffmpeg, motion, recording, etc.): `auth` (cookie
name / session length, used to size the re-login story) and `cameras` (name -> `enabled`).
`enabledCameraNames` is the sorted, filtered list the camera list actually renders.

## Feature: Cameras (P2)

- `Features/Cameras/CameraListView.swift` + `CameraGridModel.swift` - a `LazyVStack` list, one
  full-width row per enabled camera (not a grid - each camera gets the full screen width, stacked
  top to bottom, free-scrolling). `CameraGridModel` fetches `GET /api/{camera}/latest.jpg?height=720`
  for every camera concurrently (`withTaskGroup`) and re-runs on a 5s loop (`startAutoRefresh()`/
  `stopAutoRefresh()`, driven from the view's `.task`/`.onDisappear` so it stops when the tab isn't
  visible).
- `Features/Cameras/CameraDetailView.swift` + `CameraDetailModel.swift` - tapping a row pushes a
  single-camera view running the same refresh pattern at the same size (720p).
- `SnapshotState.loaded` carries a `Snapshot { data, capturedAt }`, not bare `Data` -
  `CameraGridModel.SnapshotState.advanced(with:fetchedAt:)` is the shared staleness rule used by
  both models: identical bytes on a refresh keep the previous `capturedAt` (a stuck stream shouldn't
  read as freshly fetched), and a failed fetch keeps showing the last good frame - `SnapshotState`
  only drops to `.failed` when nothing has ever loaded for that camera.
- `SnapshotImage` (in `CameraListView.swift`) renders the shared `loading` / `loaded(Snapshot)` /
  `failed` states for both the list row and the detail view.
- `Features/Cameras/SnapshotAgeBadge.swift` - the bottom-right freshness badge (Apple Home-style):
  "Now" for a few seconds after a fetch, then a relative age ("5s ago", "1m ago", "1h ago", "1d ago")
  via a `TimelineView(.periodic(from:by:))` that ticks once a second independent of the image redraw.
  Locale is pinned to en_US since nothing else in the app is localized yet.

## Feature: Settings

`Features/Settings/SettingsView.swift` - server URL, connection status, and log out. Minimal by
design; expands in P8 (full settings parity with the PWA).

## Feature: Events (P3)

Built on `GET /api/review` (activity **segments** - severity-tagged, grouped detections - not raw
per-object events; see `../DECISIONS.md` ADR-009 for why).

- `Models/ReviewSegment.swift` - the decoded row plus display helpers (`thumbnailPath` strips the
  `/media/frigate/` prefix `thumb_path` comes back with; `objectSummary`; `startDate`; `duration`).
  `hasBeenReviewed` is `var`, not `let`, so the detail screen can flip it locally after a
  successful server round-trip.
- `Features/Events/EventsModel.swift` - owns `state` (`.loading`/`.loaded([ReviewSegment])`/
  `.failed`), `filters` (`EventFilters.swift`), and pagination (`hasMorePages`/`isLoadingMore`).
  `load()` refetches from the top (used on appear, pull-to-refresh, and filter change);
  `loadMore()` pages older activity, always sending `before` **and** `after` together (the server
  silently re-defaults a missing `after` to 24h - see `../LEARNINGS.md`), de-duping by id, and
  guarding against a filter change landing mid-fetch.
- `Features/Events/EventsView.swift` - the tab root: a day-grouped `List` of `ReviewCardView` rows,
  a filter sheet (`EventFilterSheet.swift`) bound to `EventsModel.filters` via the same
  `@Bindable`-shadow pattern `ServerSetupView` uses, and an `.onAppear` on the last row driving
  `loadMore()`.
- `Features/Events/ReviewThumbnail.swift` - a self-fetching, cookie-authed image view (like
  `AsyncImage` but routed through `FrigateClient` for 401-retry); reused by the card and the
  detail screen.
- `Features/Events/ReviewDetailView.swift` + `ReviewDetailModel.swift` - tapping a segment pushes
  metadata (camera/severity/time span/objects/zones) and a mark-reviewed toggle
  (`POST /api/reviews/viewed`); the mutation is reported back to `EventsModel.updateSegment(_:)`
  so the list reflects it without a full reload. A failed toggle surfaces an inline error
  (`ReviewDetailModel.errorMessage`) rather than failing silently.
- `Features/Events/ClipPlayerView.swift` - full-screen `AVKit.VideoPlayer` playback of a segment's
  clip via the **HLS VOD manifest**, not the progressive `clip.mp4` route - see `../DECISIONS.md`
  ADR-011 for why, including the cookie-auth-on-HLS-segments reasoning. **Not yet verified on a
  physical device** (see `../ROADMAP.md`).
- `Networking/Endpoint.swift`'s `basePath` field (ADR-010) lets `reviewThumbnail`/`reviewClipHLS`
  address routes outside `/api/` through the same client/auth/retry path as everything else.

## Feature: Live video (P4)

WebRTC through go2rtc, on the camera detail screen only. Frigate exposes **no live HLS** at all -
see `../DECISIONS.md` ADR-012 for the finding and the WebRTC -> MSE -> MJPEG tier ladder it produced.

- `Models/LiveTransport.swift` - `LiveTransport` enumerates all three tiers; `LiveStreamSource`
  resolves a camera to an ordered ladder. Only `.webrtc` has an implementation today. Which stream
  to open is decided by *label* (a main-stream label beats a sub-stream one) rather than by
  position, because JSON key order does not survive `JSONDecoder` - see `../LEARNINGS.md`.
- `Features/Live/LivePlayer.swift` - the seam. A protocol plus `LivePlayerState`/`LivePlayerError`
  and `LivePlayerFactory`, which builds the best rung implemented in this build and returns `nil`
  when none are. P4.1 (MSE) and P4.2 (MJPEG) each land as one conformer plus one factory case.
  `.playing` means **pixels on screen**, not merely "the transport connected".
- `Features/Live/WebRTCSignaling.swift` - go2rtc's `{"type","value"}` envelope and the handshake
  ordering rule that matters: candidates arriving before the answer are held and released after it,
  since `RTCPeerConnection.add(_:)` rejects them otherwise.
- `Networking/LiveSocket.swift` - an actor over `URLSessionWebSocketTask`, built from
  `FrigateClient`'s own session so it inherits the cookie jar and the insecure-trust delegate.
  Conforms to `SignalingChannel`, which is what makes the handshake testable without a server.
- `Features/Live/WebRTCLivePlayer.swift` - peer connection lifecycle, video-only `recvonly`
  negotiation, and the connection-state mapping (extracted as a pure `nextState(for:…)` so the
  decisions behind the user-facing errors are unit-tested).
- `Features/Live/PeerConnectionObserver.swift` / `VideoFrameObserver.swift` - both `nonisolated`,
  because libwebrtc calls them from its own threads. The frame observer is an `RTCVideoRenderer` on
  the track rather than a delegate of the video view; `../LEARNINGS.md` explains why that
  distinction cost an evening.
- `Features/Live/LiveCameraModel.swift` - lifecycle, reconnect policy, deadlines and teardown. The
  policy lives here rather than in the player so every future tier inherits it.
- `Features/Cameras/CameraDetailView.swift` - the only place live runs. The camera list stays on the
  P2 snapshot loop ("never live-stream a grid"), and the snapshot stays *underneath* the video
  rather than being swapped out, so a failure degrades to a working picture.

Diagnostics go to `com.sagarp.Frigate` / `live` (`LiveLog`), including an `inbound-rtp` probe -
`bytesReceived` and `framesDecoded` are what separate "the media path is blocked" from "the media
path works and nothing is consuming it", which look identical on screen.

## App shell

`App/MainTabView.swift` is the tab bar (Cameras / Events / Settings) shown once `AppModel` reaches
`.connected`; each tab owns its own `NavigationStack`.

## Concurrency notes

The app target compiles with `-default-isolation=MainActor` (the project default), so plain types
are `@MainActor` unless marked `nonisolated`. `FrigateClient` is an `actor` and defines its own
isolation; value types it hands across that boundary (`Endpoint`, `FrigateConfig`, `LoginRequest`,
`APIError`, etc.) are explicitly `nonisolated`. See `../LEARNINGS.md` for the sharp edges here
(extensions don't inherit a type's `nonisolated`, `URLProtocol`/`URLSessionDelegate` subclasses
must stay `nonisolated`, etc.).
