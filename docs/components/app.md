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
`enabledCameraNames` is the sorted, filtered list the camera grid actually renders.

## Feature: Cameras (P2)

- `Features/Cameras/CameraGridView.swift` + `CameraGridModel.swift` - a `LazyVGrid` of tiles, one
  per enabled camera. `CameraGridModel` fetches `GET /api/{camera}/latest.jpg?height=300` for every
  camera concurrently (`withTaskGroup`) and re-runs on a 5s loop (`startAutoRefresh()`/
  `stopAutoRefresh()`, driven from the view's `.task`/`.onDisappear` so it stops when the tab isn't
  visible).
- `Features/Cameras/CameraDetailView.swift` + `CameraDetailModel.swift` - tapping a tile pushes a
  single-camera view running the same refresh pattern at a larger size (720p).
- `SnapshotImage` (in `CameraGridView.swift`) renders the shared `loading` / `loaded(Data)` /
  `failed` states for both the grid tile and the detail view.

## Feature: Settings

`Features/Settings/SettingsView.swift` - server URL, connection status, and log out. Minimal by
design; expands in P8 (full settings parity with the PWA).

## Feature: Events

`Features/Events/EventsPlaceholderView.swift` is a placeholder tab; the real events timeline is
P3.

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
