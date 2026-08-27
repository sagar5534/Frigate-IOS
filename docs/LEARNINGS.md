# Learnings

Gotchas worth remembering, captured as they surface. Newest first.

## A test that "passes" can still be exercising nothing

P3's C6 pagination tests initially used a 1-item first page as the `loadMore()` fixture. Every
`loadMore`-related assertion passed - but for the wrong reason: `EventsModel` correctly treats a
page smaller than its page size (100) as "no more history," so `hasMorePages` went `false` right
after the *first* `load()`, and every subsequent `loadMore()` call in the tests silently no-op'd
before ever reaching its real logic (cursor math, de-dupe, append). `xcodebuild test` was green
throughout. The bug only surfaced when the fixtures were corrected to a 100-item page (matching
the real page size) and several assertions then failed against the *actual* `loadMore()` code path
for the first time. Lesson: a green suite proves the assertions held, not that the code path under
test actually ran - when a test depends on crossing an internal threshold (a page-size cutoff, a
retry limit, a cache-eviction count), the fixture has to genuinely cross it, or the test is
inert. Independent review caught a second, subtler instance of the same trap in a follow-up test
(a "stops on an all-duplicate page" test used a *short* duplicate page, which independently
produces the same `hasMorePages == false` outcome regardless of whether the duplicate-detection
guard being tested existed at all).

## Frigate's `/api/review` (and `/api/events`) silently re-default a missing `after` to 24h

Passing `before` without `after` doesn't mean "no lower bound" - the server defaults `after` to
`datetime.now() - timedelta(hours=24)` regardless of what `before` says. A "load older" pagination
cursor that only walks `before` backward returns nothing once it pages past 24 hours ago, with no
error - it just looks like history stops existing. Any cursor against this endpoint must send both
bounds on every request, including page 2+ (`EventsModel.loadMore`, `Endpoint.review`).

## A review segment's thumbnail lives outside `/api/`, and needs a path transform

`GET /api/review` returns `thumb_path` as a **server filesystem path**
(`/media/frigate/clips/review/thumb-<camera>-<id>.webp`), not a request path. The actual HTTP
route serving that file is `{base}/clips/review/thumb-....webp` (cookie-authed, off the server
root) - strip the `/media/frigate/` prefix to get there (`ReviewSegment.thumbnailPath`). This
doesn't generalize to a rule like "strip `/media/frigate/`" for every media path; it's specific to
how nginx roots the `/clips/` location - confirmed by reading the PWA's own transform
(`ReviewCard.tsx`) rather than guessing.

## nginx-vod-module's `secure_token` on Frigate's `/vod/` is a query-string passthrough, not a signing requirement

Frigate's nginx config sets `secure_token $args;` on the `/vod/` location (HLS manifests/segments).
This nginx-vod-module directive appends a request's own query string to the segment URLs it
generates inside a manifest - it is **not** an independent auth/signing check. Since app requests
to `/vod/.../master.m3u8` carry no query string, `$args` is empty and the directive is a no-op.
The actual gate on `/vod/` is the same `auth_request` (cookie-forwarding) mechanism used
everywhere else behind Frigate's auth proxy, applied per-request to the manifest and each segment
fetch alike. Worth knowing before assuming an unfamiliar nginx directive implies extra
client-side work - read what the directive actually does, not just its name.

## A bare `HTTPCookieStorage()` doesn't actually capture `Set-Cookie` for `URLSession`

`FrigateClient` gave each client its own private jar via `config.httpCookieStorage =
HTTPCookieStorage()` (the plain no-arg initializer) so servers wouldn't cross-contaminate. Login
returned `200` with a valid `frigate_token` `Set-Cookie`, but the very next request on the same
session came back `401` - confirmed via `log stream`: the follow-up `GET /api/config` was only
235 bytes, too small to contain the ~190-byte cookie header, so it plainly wasn't attached.
`URLSession` doesn't reliably wire automatic `Set-Cookie` capture/injection into a jar created this
way. The working private-jar API is `HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier:)`
(reusing `ServerConfigStore.appGroupSuite`), which is disk-backed and happens to double as a store
the future Notification Service Extension can share. Existing tests didn't catch this because they
exercise `FrigateClient` through `MockURLProtocol`, which never touches a real cookie jar - only a
live-server run surfaces it.

## Default App Transport Security blocks plain-HTTP LAN connections; the fix needs a real Info.plist merge

Frigate's authenticated proxy (port 8971) is plain HTTP unless the user fronts it with their own
TLS reverse proxy - the app's `https://` default (see `ServerURL.normalize`) then fails to connect,
and the `http://` fallback gets silently blocked by iOS's default ATS policy before it ever reaches
the network. Fix: `NSAppTransportSecurity` / `NSAllowsLocalNetworking = true`, scoped to private/
link-local addresses (not a blanket `NSAllowsArbitraryLoads`). `GENERATE_INFOPLIST_FILE = YES`
doesn't support nested-dict keys via `INFOPLIST_KEY_*` (those only cover flat top-level values), so
this needs an actual `Info.plist` file merged in via `INFOPLIST_FILE = Frigate/Info.plist` alongside
`GENERATE_INFOPLIST_FILE = YES` - Xcode merges the two. **Gotcha:** because `Frigate/` is a
`PBXFileSystemSynchronizedRootGroup`, Xcode auto-adds the new `Info.plist` to Copy Bundle Resources
too, which collides with the Info.plist processing step ("Multiple commands produce ... Info.plist").
Needs a `PBXFileSystemSynchronizedBuildFileExceptionSet` on the group excluding `Info.plist` from
target membership.

## Timer-loop tests that race a mock's background-thread callback against wall-clock sleeps are flaky

`CameraGridModelTests.testStopAutoRefreshStopsFurtherFetches` originally started a 10ms refresh
loop, slept 60ms, called `stopAutoRefresh()`, slept another 60ms, and asserted the fetch count
hadn't moved. It failed ~5/8 runs in isolation. Cause: `MockURLProtocol`'s request handler fires on
a background queue (real `URLSession`/`URLProtocol` delivery), completely decoupled from the
`@MainActor` timing of the model's own loop - there's no guarantee `stopAutoRefresh()` lands
between fetches rather than racing an in-flight one. Fix: synchronize on the first fetch via an
`XCTestExpectation` instead of a sleep. The determinism doesn't actually depend on `stop` landing
between fetches - cancellation prevents the loop from ever re-entering `refreshAll()` afterwards, so
at most one fetch can occur no matter when `stopAutoRefresh()` runs relative to the in-flight one; a
300ms interval just keeps the "wait past it, confirm no second fetch" assertion fast. Any test that
mixes a Swift Concurrency timer loop with a mock network callback needs a real synchronization point
(expectation/continuation), not two sleeps racing each other - it'll pass most runs and hide the
flake until CI eventually catches it.

## The snapshot resize query param is `height`, not `h`

`GET /api/{camera}/latest.jpg` resizes server-side via `MediaLatestFrameQueryParams.height`
(FastAPI/pydantic, no alias). A few PWA call sites pass `?h=500` instead - that's a dead/ignored
param (FastAPI silently drops unknown query keys), so those call sites actually get a full-size
image, not a 500px one. Confirmed directly against a live server: `?h=150` returned the untouched
640x360 original while `?height=150` returned a real 266x150 resize. Don't copy the `h=` shorthand
from PWA source without checking the actual query-param model.

## Frigate's real `/api/config` payload is huge; decode only what's needed

The live payload (`~/Documents/frigate`, confirmed against frigate.sagarp.ca) has dozens of
top-level keys (`detect`, `ffmpeg`, `motion`, `objects`, `record`, ...) per camera. `FrigateConfig`
intentionally decodes a small subset (`auth`, `cameras[].enabled`) and lets `Decodable` ignore the
rest. Camera `enabled` isn't present in every fixture/legacy payload, so `CameraConfig` defaults it
to `true` via a custom `init(from:)` rather than requiring the key.

## `saveToken` in `CredentialStoring` is `async`; sync test call sites don't error until built

`CredentialStoreTests` had two call sites (`testInMemoryTokenSlotAndClear`,
`testKeychainTokenMirrorSlot`) calling `try store.saveToken(...)` without `await` in non-`async`
test functions - a hard compile error, not a warning. It had been broken since the P1 commit; it
only surfaces when `xcodebuild test` actually compiles the test target (a plain build of the app
target doesn't touch test files), so it's worth periodically running the full test target, not just
trusting a stale "N tests passing" figure in the roadmap notes.

## The login request must be exempt from the 401 retry seam

`FrigateClient` re-authenticates on a `401` by calling the credential provider, which re-runs
`/api/login`. If `login` is itself allowed to trigger that path, a wrong stored password recurses
forever: `login` 401 -> reauthenticate -> `login` 401 -> ... The fix is a single guard in the
client (`endpoint.path != "login"`). This never surfaced in C1 because login tests ran with no
credential provider; it only bites once a real provider (C5) is attached. Any future
auth/token-exchange endpoint added to the retry-eligible surface needs the same exemption.

## AppModel persistence pollutes real storage in tests unless stores are injected

`AppModel`'s production defaults are the real Keychain (`KeychainCredentialStore()`) and the
App-Group `UserDefaults` suite (`ServerConfigStore()`). Any test that drives `connect`/`submitLogin`
will write to them for real. Tests must inject an in-memory credential store and a temp-suite
`ServerConfigStore` (see `makeTestAppModel`); `ServerConfigStore(defaults:)` + a UUID suite name,
cleaned up with `removePersistentDomain(forName:)`, keeps it hermetic.

## App Group as a Keychain access group is NOT team-prefixed

iOS prefixes ordinary `keychain-access-groups` entries with the team id (`$(AppIdentifierPrefix)`),
but an **App Group id used as a keychain access group is the exception - it is used verbatim**. So
the entitlement entry and the runtime `kSecAttrAccessGroup` are both just `group.com.sagarp.Frigate`
(no `LL6476HKHT.` prefix). This is why C4 deviates from the plan's `$(AppIdentifierPrefix)group...`
sketch. Confirmed on the iPhone 17 simulator: the app signs with the entitlement and a real
`SecItem` save/read/clear against the shared group passes. Hosted unit tests inherit the host app's
entitlement, so they can exercise the shared access group directly (no separate entitlement on the
test target).

## `MockURLProtocol.requestHandler` runs off the main actor

The handler closure is `@Sendable` and invoked on a background queue. In a `@MainActor` test class,
any helper it calls (e.g. a `HTTPURLResponse` factory) must be marked `nonisolated`, or the build
fails with "call to main actor-isolated instance method in a synchronous nonisolated context."
Precompute main-actor values (like response `Data`) before setting the handler, and keep the
closure body limited to nonisolated work.

## Adding a unit-test target to a file-system-synchronized Xcode project (objectVersion 77)

The project uses `PBXFileSystemSynchronizedRootGroup`, so source files under `app/Frigate/` are
auto-discovered - no `project.pbxproj` entry per file. The `FrigateTests` target reuses the same
mechanism: a `PBXFileSystemSynchronizedRootGroup` at `app/FrigateTests/` listed in the target's
`fileSystemSynchronizedGroups` means new `.swift` test files are picked up automatically (build
phases stay empty; Xcode assigns by file type). Wiring a test target by hand still needs the
usual objects: native target (`com.apple.product-type.bundle.unit-test`), product `.xctest`
file ref, `TEST_HOST`/`BUNDLE_LOADER` pointing at the app, a `PBXTargetDependency` +
`PBXContainerItemProxy` on the app, `TestTargetID` in `TargetAttributes`, config list + Debug/
Release configs, and a `<Testables>` entry in the shared scheme's `TestAction`.

## `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (project default)

The app target defaults every non-actor type to `@MainActor`. `URLSessionDelegate` and
`URLProtocol` subclasses are called off the main actor, so mark them `nonisolated` (e.g.
`InsecureTrustDelegate`, and the test `MockURLProtocol`) or the overrides won't match their
`nonisolated` superclass declarations. `actor FrigateClient` defines its own isolation domain and
is unaffected. The test target omits this setting, so its `URLProtocol` subclass compiles cleanly.

The same default bites the networking/model layer that `actor FrigateClient` consumes: a value
type left at the default `@MainActor` gets a main-actor-isolated `Codable`/`Equatable` conformance
and main-actor-isolated static methods, which the actor can't touch ("Main actor-isolated
conformance ... cannot be used in actor-isolated context", "... static method 'login' cannot be
called from outside of the actor"). Fix is to mark the off-main-actor types `nonisolated`
(`Endpoint`, `FrigateConfig`, `LoginRequest`, `HTTPMethod`, `APIError`, `CredentialProviding`,
`CredentialStoring`, `CredentialAccount`, `KeychainCredentialProvider`) rather than disabling the
project-wide default (UI code still wants MainActor-by-default). **Gotcha:** `nonisolated` on the
primary type declaration does not cover members declared in an `extension` - the extension inherits
the MainActor default independently, so `Endpoint`'s static builders needed `nonisolated extension
Endpoint { ... }` too.

## Looping video in a card (Recent Activity strip)

Four things that are not obvious and each cost a real behaviour if missed:

- **`AVKit.VideoPlayer` steals taps.** It installs a tap gesture recognizer (to reveal its
  transport bar), so a card wrapped in a `NavigationLink` looks right and is untappable. It also
  letterboxes onto black with no aspect-fill option. For chrome-less card playback, host an
  `AVPlayerLayer` via `UIViewRepresentable` (override `UIView.layerClass` so the layer resizes
  with the view for free) and set `.allowsHitTesting(false)` on the SwiftUI side.
- **`AVPlayerLooper` depends on `AVQueuePlayer`'s default `actionAtItemEnd == .advance`.** Setting
  `.none` - the idiom you'd reach for with the manual `AVPlayerItemDidPlayToEndTime` +
  `seek(.zero)` loop - silently disables looping. The looper must also be strongly retained;
  looping stops the moment it deallocates. `teardown()` has to `disableLooping()` before releasing
  the player, or the pipeline leaks.
- **An `AVPlayerLayer` with no frame yet is transparent, not black.** Stacking one over a still
  thumbnail in a `ZStack` gives you the loading state and the failure fallback for free: a card
  whose video 404s just stays a still image. Crossfade on the layer's `isReadyForDisplay` (KVO) -
  both `play()` returning and `item.status == .readyToPlay` fire before a frame is actually up.
- **iOS caps simultaneous H.264 decode sessions** at an undocumented 3-4, and past it the failure
  is silent (`.readyToPlay` but black, or `AVFoundationErrorDomain -11800`). A `LazyHStack` of
  220pt cards realizes ~2 visible + 1-2 buffered, which fits only because `teardown()` runs on
  `.onDisappear`. `.task(id:)` and `.onDisappear` share the same lifecycle, so a card torn down by
  navigating away restarts cleanly on return.

Unrelated but adjacent: `@Observable` fires on *assignment*, not on change. A poll that re-publishes
an identical list still invalidates the view - guard on equality before assigning, or a 30s refresh
re-identifies the cards and restarts their playback.
