# P4 - Live Video (WebRTC)

## Context

P1-P3 are done: the app connects and authenticates (cookie session, silent 401 re-login), shows a
list of auto-refreshing camera snapshots with a Recent Activity strip, and browses review segments
with filters, detail, mark-reviewed, pagination, and clip playback. `FrigateClient` (actor) is the
single HTTP entry point; every route shape the app needs (JSON, JPEG, WebP, HLS VOD manifest)
already flows through its auth/retry path via `Endpoint.basePath` (ADR-010).

P4 is the roadmap milestone _"watch a live camera."_ Today the camera detail screen is a snapshot
polled every 5s; P4 replaces that with moving video for the focused camera.

Branch: `P4-Live-Video` (off `main`).

---

## Scope: this phase is WebRTC only

**Frigate exposes no live HLS.** The original plan ("ship `HLSPlayer`, WebRTC later") is void; the
finding and the full evidence live in `docs/DECISIONS.md` **ADR-012**. Live view is instead a
three-tier ladder, and **each tier is its own phase**:

| Phase | Tier | Status |
|---|---|---|
| **P4 (this plan)** | WebRTC via go2rtc | building now |
| P4.1 | MSE (fMP4 over WebSocket) | deferred, demand-driven |
| P4.2 | MJPEG (`multipart/x-mixed-replace`) | deferred, demand-driven |

P4 builds **only the WebRTC rung**, but it builds **the whole ladder's seam**, so P4.1 and P4.2
each land as one new `LivePlayer` conformer plus one case in a factory, with no call-site changes.
That seam is a first-class deliverable of this phase, not a side effect.

The consequence to hold onto: until P4.1/P4.2 exist, a user whose network cannot carry WebRTC's
media path has **no live view at all**. So the failure states in C5 are not polish - they are the
difference between "your router needs port 8555 forwarded" and an infinite spinner.

---

## Verified Frigate facts (read from `~/Documents/frigate`, go2rtc v1.9.14)

**Is a camera restreamed?** `/api/config` carries `go2rtc.streams` (dict of stream name -> source)
and per-camera `live.streams` (dict of friendly label -> go2rtc stream name,
`frigate/config/camera/live.py`). The PWA treats a camera as restreamed when the **first value** of
`cameras[name].live.streams` is a key of `go2rtc.streams`, and uses that value as `src`
(`web/src/hooks/use-camera-live-mode.ts`, `web/src/components/player/LivePlayer.tsx:264`).

**`live.streams` is never empty in the response.** `frigate/config/config.py:990-991` fills it with
`{name: name}` when the user did not configure it, so the client always sees at least one entry.
That removes the "camera name as implicit default" special case the earlier draft of this plan
carried. Note also that `verify_valid_live_stream_names` (`config.py:265`) *returns* rather than
raises its `ValueError`, so a `live.streams` value naming a nonexistent go2rtc stream reaches us
intact - the membership check is genuinely load-bearing, not belt-and-braces.

**go2rtc stream values are string-or-array.** `go2rtc: streams: front: [url1, url2]` is a normal
config. Only the **keys** matter to us, so decode them without touching the values.

**WebRTC signaling** (`web/src/components/player/WebRTCPlayer.tsx`):
1. Open `ws(s)://{base}/live/webrtc/api/ws?src={streamName}` (cookie-authed by nginx).
2. Add `recvonly` transceivers, `createOffer()`, `setLocalDescription`.
3. Send `{"type":"webrtc/offer","value":<sdp>}`.
4. Receive `{"type":"webrtc/answer","value":<sdp>}` -> `setRemoteDescription`; exchange
   `{"type":"webrtc/candidate","value":<candidate>}` both ways. **Remote candidates arrive with no
   sdpMid/sdpMLineIndex - the PWA supplies `sdpMid: "0"` itself.**
5. The PWA configures `bundlePolicy: max-bundle` and `stun:stun.l.google.com:19302` as a fallback
   ICE server, and treats "no frame within 5s" as a startup failure, "no progress for 3s" as a
   stall.

There is also a non-trickle `POST /api/go2rtc/webrtc?src={stream}` (POST-only in nginx, used by the
HA integration) if the WS path proves awkward: same auth, one round trip, at the cost of waiting
for full ICE gathering.

**Auth:** nginx gates `/live/webrtc/api/ws` with the same `auth_request` used by `/clips/` and
`/vod/`, so the handshake needs the `frigate_token` cookie. Creating the task from
`FrigateClient`'s own `URLSession` gets both the shared cookie jar and the `InsecureTrustDelegate`;
the cookie is also set explicitly on the handshake request as a belt. Scheme maps `http->ws`,
`https->wss`.

**Media path:** a separate TCP/UDP connection on **port 8555**, not the HTTPS origin. External
access needs 8555 forwarded; LAN access needs the machine's IP in go2rtc's `webrtc: candidates:`.
`create_config.py` defaults candidates to `["stun:8555"]` plus an add-on-discovered internal
candidate when present. For this deployment, `frigate.sagarp.ca:8555/tcp` answers from the public
internet today and go2rtc supports WebRTC over TCP, so the primary path should work on the real
server from day one - **which is why every chunk below has a real-server milestone, not just a
green test.** P3's clip playback shipped on reasoning alone; this phase does not repeat that.

---

## Dependency: one library, and only one

**`stasel/WebRTC`, pinned to an exact version** (151.0.0 at time of writing).

```swift
.package(url: "https://github.com/stasel/WebRTC.git", exact: "151.0.0")
```

Unmodified upstream libwebrtc, built in the open via GitHub Actions, distributed as a dynamic
xcframework, iOS 12+ (we target 26.5). Chosen over LiveKit's `webrtc-xcframework` (137.7151.x),
which renames the module to `LiveKitWebRTC` and prefixes every Objective-C symbol with `LK` for
vendoring inside their own SDK, and tracks a considerably older libwebrtc. LiveKit's stays the
documented fallback if stasel's distribution ever stalls.

**Why nothing else is worth taking**, having looked:

- **A full WebRTC SDK (LiveKit, Daily, Agora) cannot help.** Their value is *their own* signaling
  and server. go2rtc's signaling is its own small protocol; no Swift client for it exists. We write
  ~100 lines of JSON-over-WebSocket either way, and taking an SDK would mean fighting its
  connection model to do it.
- **A WebSocket library (Starscream, etc.) would be a downgrade.** `URLSessionWebSocketTask` is the
  right choice *specifically* because a task created from `FrigateClient`'s session inherits the
  shared cookie jar and the `InsecureTrustDelegate`. A third-party socket throws both away and we
  would re-implement cookie forwarding and self-signed-cert trust by hand.
- Pin exactly. These are prebuilt binaries; a surprise minor bump can break the build in ways we
  cannot patch.

---

## Architecture

New code lands under `app/Frigate/Features/Live/`, plus additive seams on `FrigateConfig`,
`Endpoint`, and `FrigateClient`. Nothing in the connect/auth/events layers changes.

```
app/Frigate/
  Models/
    FrigateConfig.swift   (edit)  + go2rtc.streams keys, cameras[].live.streams        [C1]
    LiveTransport.swift           the full three-tier ladder + resolution              [C1]
  Networking/
    Endpoint.swift        (edit)  + .webrtcWebSocket(src:)                             [C1]
    FrigateClient.swift   (edit)  + webSocketURL(for:), liveSocket(for:)               [C1]
    LiveSocket.swift              actor over URLSessionWebSocketTask                   [C1]
  Features/Live/
    LivePlayer.swift              protocol + state + errors + LivePlayerFactory        [C1]
    SignalingChannel.swift        protocol seam LiveSocket conforms to (testability)   [C1]
    WebRTCSignaling.swift         go2rtc offer/answer/candidate state machine          [C2]
    WebRTCLivePlayer.swift        peer connection lifecycle + track handoff            [C3]
    PeerConnectionObserver.swift  nonisolated delegate -> main-actor events            [C3]
    LiveVideoView.swift           UIViewRepresentable over RTCMTLVideoView             [C3]
    LiveCameraView.swift          still -> live swap, fullscreen, error states         [C4]
    LiveCameraModel.swift         owns the ladder, the player, and teardown            [C4]
```

### The seam (built in P4, consumed by P4.1 and P4.2)

**`LivePlayer`** - a protocol, not a class hierarchy. Each player owns its own render surface,
because the surfaces are genuinely different (`RTCMTLVideoView` vs `AVSampleBufferDisplayLayer` vs
an `Image`), and that keeps Metal-layer details out of SwiftUI call sites.

```swift
@MainActor
protocol LivePlayer: AnyObject {
    var state: LivePlayerState { get }
    var transport: LiveTransport { get }   // what tier this actually is, for the UI to say so
    func start()                            // idempotent
    func stop()                             // full teardown; safe to call twice
    var view: AnyView { get }
}
```

**`LiveTransport`** enumerates **all three tiers now**, even though only one is buildable in P4.
This is the point of the seam: the ladder is data, not a hardcoded choice.

```swift
nonisolated enum LiveTransport: Equatable, Sendable {
    case webrtc(streamName: String)   // P4
    case mse(streamName: String)      // P4.1
    case mjpeg(camera: String)        // P4.2
}

nonisolated enum LiveStreamSource {
    /// Ordered preference ladder for a camera, best rung first.
    /// Restreamed  -> [.webrtc(s), .mse(s), .mjpeg(camera)]
    /// Unrestreamed-> [.mjpeg(camera)]
    static func ladder(camera: String, config: FrigateConfig) -> [LiveTransport]
}
```

**`LivePlayerFactory`** builds the best rung that has an implementation *in this build*, skipping
the rest, and returns `nil` when none do (the UI then keeps the snapshot and says live is
unavailable for this camera):

```swift
@MainActor
struct LivePlayerFactory {
    func makePlayer(for ladder: [LiveTransport], client: FrigateClient) -> LivePlayer?
}
```

In P4 it knows `.webrtc` and returns `nil` for `.mse`/`.mjpeg`. P4.1 and P4.2 each add exactly one
case. **Automatic escalation on failure - try the next rung when this one dies - is deliberately
deferred to P4.2.** With one implemented rung there is nothing to escalate to, and a state machine
with no second rung to test against is speculation. Because the ladder is already an ordered list,
adding escalation later is additive to `LiveCameraModel`, not a redesign.

**States and errors:**

```swift
nonisolated enum LivePlayerState: Equatable, Sendable {
    case idle, connecting, playing, stalled
    case failed(LivePlayerError)
}
nonisolated enum LivePlayerError: Equatable, Sendable {
    case signalingFailed     // couldn't reach or negotiate with go2rtc
    case iceFailed           // negotiated, but no candidate pair connected (port 8555)
    case connectionLost
    case notAvailable        // no implemented tier for this camera
}
```

`iceFailed` is its own case on purpose: it is the one failure with a specific, explainable cause,
it is what P4.2 will eventually key its fallback off, and until then it is the thing the UI must
say out loud instead of spinning.

### Concurrency

The app target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so this phase walks into
the sharp edges already recorded in `LEARNINGS.md`:

- **Every off-main type needs explicit `nonisolated`** - `LiveTransport`, `LivePlayerState`,
  `LivePlayerError`, the signaling message enum - *and so do their extensions*, which do not
  inherit the annotation.
- **`RTCPeerConnectionDelegate` callbacks arrive on WebRTC's own threads.** Rather than making
  `WebRTCLivePlayer` itself `nonisolated`, a small `nonisolated final class
  PeerConnectionObserver` conforms to the delegate and forwards events to the main actor through
  an `AsyncStream`. Same pattern as `InsecureTrustDelegate`, and it keeps the player ordinary
  main-actor code.
- **`LiveSocket` is an actor** wrapping `URLSessionWebSocketTask`, so the non-`Sendable` task never
  crosses an isolation boundary; received frames reach the player as an `AsyncStream`.

### Grid stays snapshots

No live streams in the camera list - the "never live-stream a grid" rule, already satisfied by the
P2 snapshot loop. One live player, focused camera only.

---

## Chunk map

- **C1 - Seam + live source resolution.** Config parsing, the `LiveTransport` ladder, the
  `LivePlayer`/factory protocols, `SignalingChannel`, and authenticated WebSocket plumbing on
  `FrigateClient`. No dependency, no video. **Detailed below.**
- **C2 - go2rtc signaling.** `WebRTCSignaling`: the message codec and handshake sequencing over a
  `SignalingChannel`. Still no dependency (this is JSON over a socket). Unit-tested against a fake
  channel; **real-server milestone: the socket opens and stays open against
  `frigate.sagarp.ca` with the session cookie, and is rejected without it.** That proves the
  nginx `auth_request` question independently of any WebRTC code - the single cheapest de-risking
  step in the phase.
- **C3 - Dependency + `WebRTCLivePlayer` + `LiveVideoView`.** Add the pinned SPM package; check app
  size and the arm64-simulator slice under Xcode 26 *before* building on it. `recvonly` video
  transceiver, remote track handoff to `RTCMTLVideoView`, ICE/connection state mapped onto
  `LivePlayerState`. **Milestone: a moving picture from a real camera on screen.**
- **C4 - Wire into camera detail.** `LiveCameraView`/`LiveCameraModel`: show the existing snapshot
  until the first frame renders, then crossfade to live; the snapshot poll stops once live is
  playing; aspect-ratio handling, tap-to-fullscreen, and distinct states for connecting / stalled /
  failed / unavailable. **Milestone: open a camera, watch it live, expand it fullscreen.**
- **C5 - Reconnect, teardown, and honest failure.** Exponential backoff on connection loss; a
  startup timeout that resolves to `.failed(.iceFailed)` with actionable copy rather than spinning;
  teardown on `.onDisappear` / `scenePhase` background / tab switch; leak check (peer connection
  closed, socket closed, tasks cancelled). **Milestone: kill wifi mid-stream and it recovers;
  block 8555 and it fails within seconds with a message that names the cause.**

_P4 milestone (all chunks): open a camera and watch it live, with automatic recovery after a
network blip and a truthful, specific failure when WebRTC cannot connect._

---

## C1 - Seam + live source resolution (FULL DETAIL)

No dependency, no video. Config + models + networking seams only, all unit-testable through the
existing `MockURLProtocol` and in-memory doubles.

### `Models/FrigateConfig.swift` (edit)

Two additive fields, both lenient - existing tests and fixtures construct configs without them and
must keep decoding.

```swift
let go2rtc: Go2RTCInfo                  // decodeIfPresent -> .init()

nonisolated struct Go2RTCInfo: Decodable, Equatable, Sendable {
    /// Only the KEYS matter. Values are string-or-array-of-string in real configs, so read the
    /// key set from a nested keyed container and never decode a value at all.
    let streamNames: Set<String>
}
```

and inside `CameraConfig`:

```swift
let live: LiveInfo                      // decodeIfPresent -> .init(streams: [])

nonisolated struct LiveInfo: Decodable, Equatable, Sendable {
    /// Sorted by label - see the ordering finding below.
    let streams: [Stream]
    struct Stream: Equatable, Sendable { let label: String; let name: String }
}
```

`CameraConfig` already has a custom `init(from:)` to extend.

**Ordering finding (resolved in C1, and the assumption was wrong).** The PWA uses
`Object.values(camera.live.streams)[0]` - the user's declaration order, which JavaScript preserves.
This plan originally assumed `JSONDecoder`'s `allKeys` would follow document order and shipped a
test to confirm it. **It does not: `allKeys` comes back in hash order**, which is neither document
order nor sorted, and Swift's per-process hash seed means it genuinely differs between app
launches. A multi-stream camera would have opened a different stream every time the app started.
Full write-up in `LEARNINGS.md`.

Resolution: `LiveInfo.streams` is **sorted by label at decode time** so the array is at least
deterministic, and `LiveStreamSource` layers a meaningful preference on top rather than trusting
position (see below). The array keeps every label, so the P8 stream picker can replace the guess
with a choice.

In practice this bites rarely: the server fills `live.streams` with `{name: name}` when unset
(`config.py:990`), so the overwhelming majority of cameras have exactly one entry.

### `Models/LiveTransport.swift` (new)

`LiveTransport` and `LiveStreamSource.ladder(camera:config:)` as specified in Architecture above.
Rules. The PWA (`use-camera-live-mode.ts`) takes the *first* `live.streams` entry; since position
is not available to us, the equivalent is:

- **Candidates** are the camera's `live.streams` values that exist as keys of `go2rtc.streams`. A
  value naming a nonexistent stream reaches us intact, because the server's own
  `verify_valid_live_stream_names` *returns* its `ValueError` instead of raising it
  (`config.py:265`), so this check is the only thing between a config typo and a permanent spinner.
- **A candidate named after the camera wins.** That is Frigate's own default mapping
  (`config.py:990`) and the near-universal convention for a main stream, so it agrees with the
  PWA's pick for the overwhelming majority of configs, single-stream ones included.
- Otherwise the alphabetically first candidate, purely for stability. This is the one guess, and
  P8's stream picker is what removes it.
- No candidates -> `[.mjpeg(camera:)]`.
- **`live.streams` empty entirely** (older/partial payload) -> apply the server's own default and
  test the camera name against the go2rtc key set. Deliberately *not* done when the camera declared
  streams and none of them exist: that is a config error, and silently playing a stream the user did
  not ask for would hide it.

This is the only place in the app that answers "how do I watch this camera?", and it is pure
functions over a value type - no client, no network, trivially testable.

### `Features/Live/LivePlayer.swift` (new)

`LivePlayer`, `LivePlayerState`, `LivePlayerError`, `LivePlayerFactory` as specified above. In C1
the factory has no cases to build yet and returns `nil`; C3 fills in `.webrtc`. Ship it in C1
anyway so C4 is written against the seam from the start rather than against a concrete player.

### `Features/Live/SignalingChannel.swift` (new)

The seam that makes C2 testable without a server - `URLSessionWebSocketTask` cannot be intercepted
by `MockURLProtocol`, so the mock has to sit one layer higher:

```swift
protocol SignalingChannel: Actor {
    func send(_ text: String) async throws
    var messages: AsyncStream<String> { get async }
    func close() async
}
```

### `Networking/LiveSocket.swift` (new) + `FrigateClient.swift` (edit)

```swift
/// Same URL composition as every other endpoint, with the scheme mapped http->ws / https->wss.
func webSocketURL(for endpoint: Endpoint) -> URL?

/// A connected WebSocket built from the client's own URLSession, so it inherits the shared cookie
/// jar and the insecure-trust delegate. The `frigate_token` cookie is also set explicitly on the
/// handshake request, because nginx `auth_request` gates this route.
func liveSocket(for endpoint: Endpoint) throws -> LiveSocket
```

`LiveSocket` is a small actor conforming to `SignalingChannel`, wrapping the task's
send/receive/cancel and turning the receive loop into an `AsyncStream`.

### `Networking/Endpoint.swift` (edit)

```swift
/// go2rtc WebRTC signaling socket. Off the server root (not `/api/`), like /clips/ and /vod/.
static func webrtcWebSocket(src: String) -> Endpoint
    // path "live/webrtc/api/ws", query src=…, basePath: nil
```

### Tests (`FrigateTests`)

- **`FrigateConfigTests`** (extend) - a payload with `go2rtc.streams` + per-camera `live.streams`
  decodes; a payload with neither still decodes (no regression for existing fixtures); go2rtc
  stream values that are strings *and* arrays both decode without throwing; `live.streams` comes
  back sorted by label from a payload whose document order is neither sorted nor reverse-sorted.
- **`LiveTransportTests`** (new) - restreamed camera -> ladder headed by `.webrtc`; the ladder
  carries the *stream* name for WebRTC and the *camera* name for MJPEG (the case a naive
  implementation conflates); unmapped camera -> `[.mjpeg]`; empty `live.streams` with a matching
  go2rtc key -> `.webrtc`; a multi-stream camera prefers the stream named after the camera even
  when another sorts earlier; a multi-stream camera with no such stream resolves *identically
  across repeated decodes*; a typo'd stream alongside a good one is skipped rather than dragging
  the camera to MJPEG; every stream typo'd -> `.mjpeg`.
- **`EndpointTests`** (extend) - `.webrtcWebSocket(src:)` -> `{base}/live/webrtc/api/ws?src=front`
  with **no** `api/` prefix.
- **`FrigateClientTests`** (extend) - `webSocketURL` maps `http`->`ws` and `https`->`wss` and keeps
  host/port/path/query; existing `authedURL` behaviour unchanged.

### Out of scope for C1 (explicit)

No SPM dependency, no peer connection, no signaling logic, no UI, no reconnect policy. C1 proves
exactly two things: we can tell how a given camera should be watched, and we can open an
authenticated socket to the right URL.

---

## C2 - go2rtc signaling (BUILT)

`SignalingMessage` is the `{"type": …, "value": …}` envelope codec for `webrtc/offer`,
`webrtc/answer` and `webrtc/candidate`. Unknown types decode to `nil` and are dropped rather than
failing the connection - the same socket API also carries MSE's `mse` handshake (P4.1), so an
unrecognised type is normal traffic, and Frigate's PWA ignores them identically.

`WebRTCSignaling` owns the protocol and nothing about the media - no reference to
`RTCPeerConnection` at all, which is what lets the whole handshake be tested with no server and no
libwebrtc binary. The one piece of real logic: **candidates that arrive before the answer are held
back and released immediately after it.** go2rtc trickles candidates as soon as it has them, so
they routinely beat the answer down the wire, and `RTCPeerConnection.add(_:)` rejects a candidate
before `setRemoteDescription`. Keeping that race here rather than in the player is what makes it
reproducible: in C3 it would need a live server and a stopwatch.

Tested against `FakeSignalingChannel`, which buffers scripted frames so each test drains a finished
stream - no timing, no expectations, no flake: encoding shapes and round-trip, answer/candidate
decoding, unknown-type and malformed frames dropped without ending the stream, an inbound offer
ignored, early candidates released in arrival order, later ones passing straight through, and the
server hanging up mid-handshake terminating cleanly.

Still to do in C3: remote candidates carry no `sdpMid`, so supply `"0"` when applying them, as the
PWA does.

**Real-server gate (before C3, and it is what justifies the binary dependency):**
`LiveServerIntegrationTests` opens the signaling socket against a real server using the stream name
C1's resolution picked from the live `/api/config`, and pings it - a pong only round-trips once the
HTTP upgrade succeeded, which distinguishes "nginx let us through" from "nginx returned 401"
without needing an SDP offer we cannot produce yet. Its sibling asserts the socket is *refused*
without the cookie. Both skip unless the environment names a server, so the suite stays hermetic:

```bash
TEST_RUNNER_FRIGATE_TEST_URL=https://frigate.sagarp.ca \
TEST_RUNNER_FRIGATE_TEST_USER=… TEST_RUNNER_FRIGATE_TEST_PASSWORD=… \
  xcodebuild -project "app/Frigate.xcodeproj" -scheme Frigate \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FrigateTests/LiveServerIntegrationTests test
```

The `TEST_RUNNER_` prefix is not optional - see `LEARNINGS.md`. Without it the tests skip silently
and the run still reports `TEST SUCCEEDED`.

It also prints the resolved transport for every enabled camera, which is the first real check of
C1's resolution against a live config rather than a fixture.

## C3 - Dependency + `WebRTCLivePlayer` + `LiveVideoView` (SUMMARY)

`stasel/WebRTC` is pinned at `exactVersion` 151.0.0 (resolved revision `19aa8c1f`), on the Frigate
target only. Precondition checks are **done**: it embeds and links under Xcode 26, the simulator
slice carries both x86_64 and arm64, and the shipping cost is 12MB on the arm64 release slice (see
`LEARNINGS.md` - the widely quoted ~30MB is a Debug simulator measurement).

`WebRTCLivePlayer` conforms to `LivePlayer`: `RTCPeerConnectionFactory`, `bundlePolicy:
.maxBundle`, the Google STUN server as fallback ICE (matching the PWA), one **video-only**
`recvonly` transceiver, `createOffer` -> `setLocalDescription` -> hand to `WebRTCSignaling`.
Remote track goes to `RTCMTLVideoView` behind a `UIViewRepresentable`.

Video-only is deliberate for P4: audio is out of scope, and requesting audio invites a class of
negotiation failure (codec mismatch against cameras with no or odd audio) for a track we would
discard. Adding it later is one transceiver.

`PeerConnectionObserver` (nonisolated) translates delegate callbacks into main-actor events;
`RTCIceConnectionState`/`RTCPeerConnectionState` map onto `LivePlayerState`, with `.failed`/
`.disconnected` distinguishing `iceFailed` from `connectionLost`.

## C4 - Wire into camera detail (SUMMARY)

`LiveCameraModel` resolves the ladder from `AppModel`'s config, asks `LivePlayerFactory` for a
player, and owns start/stop. `LiveCameraView` stacks the live surface over the existing snapshot
and crossfades on first frame (`RTCVideoViewDelegate.didChangeVideoSize` is the signal; the Metal
view is transparent until then, which gives the loading state for free - same trick as the Recent
Activity strip's `AVPlayerLayer`, see `LEARNINGS.md`). The snapshot poll stops once state reaches
`.playing` and resumes if live fails. Tap to fullscreen; `.notAvailable` keeps the P2 snapshot
experience unchanged rather than showing an error.

## C5 - Reconnect, teardown, honest failure (SUMMARY)

Exponential backoff on `connectionLost`. A startup deadline (the PWA uses 5s) that resolves to
`.failed(.iceFailed)` rather than spinning, and a stall deadline (3s without frames) that shows
`.stalled` before dropping to reconnect. Teardown on `.onDisappear`, `scenePhase` background, and
tab switch; verify the peer connection is closed, the socket closed, and every task cancelled.

Because no fallback tier exists yet, `iceFailed` copy must name the cause and the fix in plain
language ("this camera's live stream can't be reached from this network - it needs port 8555 open
to the app") with a Retry, plus the snapshot still visible underneath. Getting this wrong is how a
correct implementation reads as a broken app.

---

## Deferred tiers: research already banked

Recorded here so P4.1 and P4.2 need no re-research.

**MSE (P4.1).** Open `/live/mse/api/ws?src={stream}`, send
`{"type":"mse","value":"<comma-separated codecs>"}`, receive a text ack naming the negotiated
codecs, then binary fMP4: init segment first, then `moof`+`mdat` pairs. No ack within ~3s is the
PWA's cue to fall back. Requires H.264/H.265 video and PCMA/PCMU or AAC audio. The work is a reader
for ~8 ISO 14496-12 box types (`ftyp`, `moov`->`mdhd`/`stsd`->`avcC`/`hvcC`, `moof`->`tfhd`/`tfdt`/
`trun`, `mdat`) feeding `CMSampleBuffer`s to `AVSampleBufferDisplayLayer`; VideoToolbox does the
decoding via `CMVideoFormatDescriptionCreateFromH264ParameterSets`. No decoder to write, but ~400-600
lines of media plumbing we would own forever. **No library removes this work** - surveyed in
ADR-012 (FragmentedMP4Parser unmaintained and file-oriented, FFmpegKit retired April 2025,
VLCKit/mpv need a URL, HaishinKit is a publishing library).

**MJPEG (P4.2).** `GET /api/{camera_name}` (`frigate/api/media.py:77`), params `fps` (default 3),
`height` (default 360), plus `bbox`/`timestamp`/`zones`/`mask`/`motion`/`regions` overlays.
Returns `multipart/x-mixed-replace;boundary=frame`; parse the boundary stream off
`URLSession.bytes`. Frames come from the **detect** stream via `get_current_frame`
(`frigate/camera/state.py:81`), resized with `cv2.resize` and encoded at JPEG quality 70 **per
connected client** (`media.py:107-127`) - so server CPU scales per viewer, asking for a `height`
above the detect resolution only upscales, and 720p at 5fps is roughly 2-5 Mbps. Defaults are low
for a reason. The server-drawn bounding-box overlay is a genuine upside no other tier offers.

---

## Risks

- **ICE reachability decides whether P4 succeeds in the real world.** With no fallback tier in this
  phase, the mitigation is honesty rather than degradation: fail fast and name the cause (C5).
  Verify early - C2's real-server milestone and C3's first live frame are both gates, not
  formalities.
- **Binary dependency** - *measured, and cheaper than feared.* `stasel/WebRTC` 151.0.0 pinned
  exactly; the shipping cost is **12MB** (arm64 release slice), not the ~30MB folklore, though that
  is still ~90% of a 13MB app. The arm64-simulator slice links cleanly under Xcode 26. See
  `LEARNINGS.md`. The residual risk is cadence: community rebuilds tie our releases to someone
  else's schedule (M151 shipped 2026-08-07, on a steady monthly rhythm).
- **Decode-session contention.** iOS caps simultaneous H.264 decode sessions at an undocumented
  3-4, and the Recent Activity strip already runs 2-4 looping players on the screen live view is
  pushed *from*. The strip tears down on `.onDisappear`, so this should be fine - but it is the
  exact documented failure mode (`LEARNINGS.md`), so check it explicitly rather than assume.
- ~~**The `live.streams` ordering assumption**~~ - **resolved in C1, and it was wrong.** `allKeys`
  is hash order and unstable across launches; resolution is now deterministic and prefers the
  camera-named stream. The residual risk is narrow: for a multi-stream camera with no
  camera-named stream we may open a different stream than the PWA would, until P8's stream picker
  lands. See `LEARNINGS.md`.
- **Carry-over from P3:** clip playback (`ClipPlayerView`) has still never been smoke-tested
  against a real server on a device. The first P4 device session should verify it in the same
  sitting - it exercises the same cookie-auth-for-media assumption this phase leans on.

## Out of scope for P4

Audio, two-way talk, PTZ, live in the camera list, recordings scrubbing, picture-in-picture,
multi-stream quality switching, the MSE demuxer (P4.1), and the MJPEG player (P4.2).

## Verification

Per chunk: `xcodebuild -project "app/Frigate.xcodeproj" -scheme Frigate -destination 'platform=iOS
Simulator,name=iPhone 17' test` stays green (105 tests today).

End-to-end (needs the real server, and a physical device for an honest latency/battery read):
open a camera -> still image appears immediately -> live video takes over within a couple of
seconds -> leave it running five minutes without stalling -> drop wifi and watch it reconnect ->
background the app and confirm the peer connection closes -> test from a network that cannot reach
8555 and confirm a fast, specific failure rather than a spinner -> open a non-restreamed camera and
confirm it reports live as unavailable while keeping its snapshot.

## Docs to update as we go

- `docs/ROADMAP.md` - flip C1-C5 statuses as they land.
- `docs/components/app.md` - add a "Feature: Live (P4)" section once code exists.
- `docs/LEARNINGS.md` - the `live.streams` ordering finding, whether the WS handshake really
  carries the cookie, the measured app-size hit, and any ICE/candidate gotchas.
- `docs/DECISIONS.md` - a follow-up ADR only if reality forces a change of approach; ADR-012
  already records the decision itself.
