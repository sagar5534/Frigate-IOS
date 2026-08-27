# P4 - Live Video

## Context

P1-P3 are done: the app connects and authenticates (cookie session, silent 401 re-login), shows a
grid of auto-refreshing camera snapshots, and browses review segments with filters, detail,
mark-reviewed, pagination, and clip playback. `FrigateClient` (actor) is the single HTTP entry
point; every route shape the app needs (JSON, JPEG, WebP, HLS VOD manifest) already flows through
its auth/retry path via `Endpoint.basePath` (ADR-010).

P4 is the roadmap milestone _"watch a live camera."_ Today the camera detail screen is a snapshot
polled every 5s - P4 replaces that with actual moving video for the focused camera.

Branch: `P4-Live-Video` (off `main`).

---

## The blocking finding: Frigate has no live HLS

The roadmap and `CLAUDE.md` both assume v1 live = **`HLSPlayer` (AVPlayer + HLS)**, with WebRTC
slotting in later. **That source does not exist.** Read directly from `~/Documents/frigate`
(commit `65af0b135`), the only live transports a Frigate server exposes are:

| Transport | URL | Auth | Native iOS story |
|---|---|---|---|
| **WebRTC (go2rtc)** | `ws(s)://{base}/live/webrtc/api/ws?src={stream}` (signaling) | nginx `auth_request` (cookie) | Needs a WebRTC binary dependency; rendering is free. |
| **MSE (go2rtc)** | `ws(s)://{base}/live/mse/api/ws?src={stream}` | same | fMP4 over WebSocket. No MSE API on iOS - the bytes must be demuxed by hand and fed to `AVSampleBufferDisplayLayer`. |
| **jsmpeg** | `ws(s)://{base}/live/jsmpeg/{camera}` | same | MPEG1 over WebSocket; no usable hardware decode path. Dead end. |
| **MJPEG** | `GET /api/{camera}?fps=&height=&bbox=&timestamp=…` | cookie (normal API path) | `multipart/x-mixed-replace` JPEG stream. Trivial to consume; not real video. |

`nginx.conf` proxies exactly four go2rtc/live locations (`/live/jsmpeg/`, `/live/mse/api/ws`,
`/live/webrtc/api/ws`, `/live/webrtc/webrtc.html`) plus `POST /api/go2rtc/webrtc`. There is **no**
generic go2rtc proxy, so go2rtc's own `stream.m3u8` and `stream.mp4` outputs are unreachable;
go2rtc's API port (1984) is bound to `127.0.0.1` inside the container and is not part of a
supported deployment. `/vod/` HLS is **recordings only** (nginx-vod-module over finalized recording
files) - that is what P3's clip playback uses, and it is not live.

Frigate's own PWA confirms the shape: it picks `mse` when the camera is restreamed and the browser
has MediaSource, `webrtc` when restreamed without MediaSource, and falls back to `jsmpeg` when the
camera is **not** restreamed (`web/src/hooks/use-camera-live-mode.ts`). It never uses HLS for live.

**So P4's real decision is which transport becomes the v1 `LivePlayer`.** The `LivePlayer`
interface itself - the part `CLAUDE.md` actually cares about - is unaffected: it stays a thin seam
so other players drop in later.

---

## Transport decision

### The candidates

**A. MSE over WebSocket -> `AVSampleBufferDisplayLayer`.** Connect the WebSocket, send
`{"type":"mse","value":"<codec list>"}`, receive a text ack then binary fMP4 (init segment, then
`moof`+`mdat` fragments), parse the boxes, enqueue `CMSampleBuffer`s. Zero dependencies, rides the
same HTTPS origin and cookie auth as everything else, so it works for **any user who can log in**.
Cost: we write the fMP4 demuxer ourselves (~400-600 lines).

**B. WebRTC via go2rtc.** Signaling over `ws(s)://{base}/live/webrtc/api/ws?src={stream}`
(cookie-authed by nginx): `recvonly` transceivers, `createOffer`, send
`{"type":"webrtc/offer","value":sdp}`, receive `{"type":"webrtc/answer","value":sdp}` plus
`{"type":"webrtc/candidate","value":…}` trickle both ways. Media is a separate connection on
**port 8555**. Sub-second latency, audio, and two-way talk later; rendering is handled by the
library.

**C. MJPEG.** `GET /api/{camera}?fps=5&height=720` streams JPEGs over the existing `FrigateClient`
path - about 150 lines, works on every server regardless of go2rtc config or ports. But the frames
come from the low-res **detect** stream, Frigate re-encodes every frame per client (`cv2.resize` +
`imencode`, `media.py:109`), and there is no audio. Not a primary experience - a real fallback.

### A vs B: the work

**On app code, B wins outright:**

| | A - MSE | B - WebRTC |
|---|---|---|
| Transport | WebSocket, ~100 lines | signaling over WebSocket, ~80 lines |
| Decode/render | **fMP4 demuxer ~400-600 lines** + `AVSampleBufferDisplayLayer` ~100 | none - `RTCMTLVideoView` renders the track |
| Dependencies | none | `WebRTC.xcframework` (~30MB binary) |
| Total app code | ~600-800 lines | **~200-300 lines** |
| Latency | ~1-2s | ~0.2-0.5s |
| Audio / two-way talk | no | yes / possible later |

### Is there a library that removes A's demuxer work?

Checked, because "don't hand-build media plumbing" is the right instinct. **There isn't a good
one:**

- **No maintained Swift package consumes a live fMP4 byte stream.** The closest hit,
  [`sbader/FragmentedMP4Parser`](https://github.com/sbader/FragmentedMP4Parser), is a
  file-oriented tool for generating HLS playlists, still on pre-Swift-4 `Package.swift` syntax at
  `majorVersion: 0`. Not a streaming demuxer, not maintained.
- **FFmpegKit is retired.** Archived January 2025; binaries pulled from CocoaPods/Maven/npm in
  April 2025. Continuations exist (`FFmpegKitNext`, `kewlbear/FFmpeg-iOS`), and the popular SPM
  fork `ffmpeg-kit-spm` retired along with upstream. Taking FFmpeg means a 30-80MB binary plus
  LGPL/GPL compliance work, on a dependency whose upstream just died - to avoid ~500 lines we
  could own outright.
- **VLCKit / mpv can't help.** They need a URL; neither speaks WebSocket. They could play go2rtc's
  RTSP on port 8554, but that has WebRTC's exposed-port problem *and* a ~100MB binary.
- **HaishinKit** is actively maintained and does contain ISOBMFF code, but it is an RTMP/SRT
  *publishing* library - its MP4 support is file reading and HLS writing, not consuming a live
  fMP4 socket. We would bend it sideways and still write the glue.

**The asymmetry is the finding:** the one transport with a well-maintained, production-grade iOS
library is **WebRTC** (LiveKit's `WebRTC-SDK` / `stasel/WebRTC`, rebuilt regularly and shipped in
production). If we don't want to hand-build, the coherent answer is WebRTC - not MSE-with-a-library,
because that library doesn't exist.

For the record, A's "hand-built" part is smaller than it sounds: we would not write a decoder.
VideoToolbox decodes, and Apple gives us `CMVideoFormatDescriptionCreateFromH264ParameterSets` /
`…FromHEVCParameterSets`. We would write a reader for ~8 box types (`ftyp`, `moov`→`mdhd` +
`stsd`→`avcC`/`hvcC`, `moof`→`tfhd`/`tfdt`/`trun`, `mdat`), fully specified by ISO 14496-12 and
testable offline against captured bytes. Tedious, not deep - but still ~500 lines of media
plumbing we'd maintain forever.

### What can go wrong with WebRTC

All from Frigate's own docs (`docs/docs/configuration/live.md`,
`docs/docs/frigate/network_requirements.md`), not speculation:

1. **It needs server-side setup the app cannot perform.** Media rides a separate TCP/UDP connection
   on **port 8555**. External access requires forwarding 8555 (both protocols) on the user's
   router. Internal/LAN access additionally requires hand-editing go2rtc's YAML with a
   `webrtc: candidates:` list containing the machine's LAN IP. Docker installs need 8555 mapped in
   `docker-compose.yml` (or `network: host`). Tailscale users must add their Tailscale IP as a
   candidate. That is router configuration plus YAML editing - the thing this project's guiding
   priority ("move fast, keep setup seamless") and its "config lives in the app UI, not YAML" rule
   exist to avoid.
2. **The media path bypasses the tunnel that already works.** Everything the app does today goes
   through one authenticated HTTPS origin, which is what makes remote access work for users behind
   Cloudflare Tunnel, Nginx Proxy Manager, Tailscale, or a plain reverse proxy. WebRTC's media does
   not use that origin. Cloudflare Tunnel carries neither UDP nor arbitrary TCP ports, so those
   users get a permanent spinner unless they separately expose 8555.
3. **Weaker auth story.** The signaling WS/POST is cookie-gated by nginx `auth_request`
   (`frigate/api/auth.py:1144`); the media connection to 8555 is go2rtc's own port, gated only by
   the ICE credentials in the SDP.
4. **Failures are invisible and un-actionable.** WebRTC fails in ICE, and the user sees
   "connecting…" forever. Saying anything useful means building candidate diagnostics, and the fix
   is always "change your router or your YAML." MSE failures are HTTP failures the existing
   `APIError` model already describes.
5. **Dependency cadence.** Google publishes no official Swift package for libwebrtc; usable SPM
   distributions are community rebuilds. A ~30MB binary dominates app size and ties releases to
   someone else's rebuild schedule each Xcode/iOS cycle.
6. **HEVC over WebRTC is spottier** than over MSE, and the PWA's player falls back to Google's
   public STUN server (internet required) when no local candidate is configured.

**And in fairness, MSE's own downsides:** ~1-2s latency instead of sub-second; no audio, ever,
without more demuxer work; a hand-written demuxer is a real bug surface on unusual streams; and it
still needs a go2rtc restream configured, or we're on MJPEG anyway.

### Decision: WebRTC primary, MJPEG fallback, MSE deferred

Objection #1/#2 above - reach - is the only serious argument against WebRTC, and it is answered
**without** the demuxer: pair WebRTC with the **MJPEG fallback (C)**, which needs no ports, no
YAML, and no go2rtc at all. Users whose network cooperates get the best live experience Frigate can
produce; everyone else gets a working, if soft, picture instead of a spinner. That covers both
reach and quality for ~350-450 lines total and one maintained dependency - versus ~600-800 lines of
hand-written demuxer that still tops out at 1-2s latency with no audio.

Supporting facts for this specific deployment: `frigate.sagarp.ca:8555/tcp` answers from the public
internet today, and go2rtc supports WebRTC over TCP - so the primary path should work on the real
server from day one, and P4 can be verified end-to-end rather than reasoned about (the mistake P3
made with clip playback).

**MSE is deferred, not discarded.** It stays the documented tier-2 upgrade: if MJPEG-tier users
turn out to be common (telemetry we don't have yet, or the first external testers), the demuxer is
a self-contained chunk that slots into the same `LivePlayer` seam without touching the UI. Building
it now would be paying ~500 lines of permanent maintenance for a population we cannot yet measure.

### Roadmap consequence

The P4 bullet "`HLSPlayer` implementation (AVPlayer + HLS)" becomes "`WebRTCLivePlayer` (go2rtc
signaling + `RTCMTLVideoView`)", with an added MJPEG-fallback bullet. `CLAUDE.md` needs two
amendments: the "ship `HLSPlayer` only for v1, `WebRTCPlayer` later" rule is inverted by this
finding (there is no HLS to ship), and "low-res HLS for the grid" becomes "snapshots for the grid"
- the grid stays on the P2 snapshot loop and live runs only on the focused camera, which preserves
the actual intent of that rule ("never WebRTC a grid").

---

## Verified Frigate facts (read from `~/Documents/frigate`)

**Is a camera restreamed?** `/api/config` carries `go2rtc.streams` (dict of stream name -> source)
and per-camera `live.streams` (dict of friendly label -> go2rtc stream name,
`frigate/config/camera/live.py:8`). The PWA treats a camera as restreamed when the **first value**
of `cameras[name].live.streams` is a key of `go2rtc.streams`, and uses that stream name as `src`.
Unmapped -> not restreamed -> jsmpeg in the PWA, MJPEG for us. Docs confirm: _"If your go2rtc
stream names don't match your Frigate camera name, you must map them with the `live -> streams`
config; otherwise the UI falls back to the video-only jsmpeg player."_

**WebRTC signaling** (`web/src/components/player/WebRTCPlayer.tsx`):
1. Open `ws(s)://{base}/live/webrtc/api/ws?src={streamName}` (cookie-authed by nginx).
2. Add `recvonly` transceivers for video (and audio), `createOffer()`, `setLocalDescription`.
3. Send `{"type":"webrtc/offer","value":<sdp>}`.
4. Receive `{"type":"webrtc/answer","value":<sdp>}` -> `setRemoteDescription`; exchange
   `{"type":"webrtc/candidate","value":<candidate>}` both ways (remote candidates use `sdpMid: "0"`).
5. The PWA also configures `stun:stun.l.google.com:19302` as a fallback ICE server.

There is also a non-trickle `POST /api/go2rtc/webrtc?src={stream}` (used by the HA integration) if
the WS path proves awkward - same auth, one round trip, at the cost of waiting for full ICE
gathering.

**MJPEG fallback** - `GET /api/{camera_name}` (`frigate/api/media.py:77`), params `fps` (default 3),
`height` (default 360), plus optional `bbox`/`timestamp`/`zones`/`mask`/`motion`/`regions`
overlays. Returns `multipart/x-mixed-replace;boundary=frame`.

**Auth:** nginx gates `/live/webrtc/api/ws` with the same `auth_request` used by `/clips/` and
`/vod/`, so the handshake needs the `frigate_token` cookie. Creating the task from
`FrigateClient`'s own `URLSession` gets both the private cookie jar and the
`InsecureTrustDelegate`; the cookie is also set explicitly on the handshake request as a belt.
Scheme maps `http->ws`, `https->wss`.

**MSE handshake** (recorded here so the deferred tier-2 work doesn't need re-research): open
`/live/mse/api/ws?src={stream}`, send `{"type":"mse","value":"<comma-separated codecs>"}`, receive
a text ack naming the negotiated codecs, then binary fMP4 - init segment first, then `moof`+`mdat`
pairs. No ack within ~3s is the PWA's cue to fall back. MSE requires H.264/H.265 video and
PCMA/PCMU or AAC audio.

---

## Architecture

New code lands under `app/Frigate/Features/Live/`, plus additive seams on `FrigateConfig`,
`Endpoint`, and `FrigateClient`. Nothing in the connect/auth/events layers changes.

```
app/Frigate/
  Models/
    FrigateConfig.swift  (edit)  + go2rtc.streams, cameras[].live.streams          [C1]
    LiveStreamSource.swift       camera -> (transport, stream name) resolution      [C1]
  Networking/
    Endpoint.swift       (edit)  + .webrtcWebSocket(src:), .mjpegStream(camera:…)   [C1]
    FrigateClient.swift  (edit)  + webSocketURL(for:), liveSocket(for:)             [C1]
  Features/Live/
    LivePlayer.swift             protocol + LivePlayerState + errors                [C1]
    WebRTCSignaling.swift        go2rtc offer/answer/candidate over the socket      [C2]
    WebRTCLivePlayer.swift       peer connection lifecycle + track handoff          [C3]
    LiveVideoView.swift          UIViewRepresentable over RTCMTLVideoView           [C3]
    LiveCameraView.swift         still -> live swap, controls, error states         [C4]
    MJPEGLivePlayer.swift        multipart JPEG fallback player                     [C6]
```

**`LivePlayer` (the seam `CLAUDE.md` mandates).** A protocol, not a class hierarchy:

```swift
@MainActor
protocol LivePlayer: AnyObject {
    var state: LivePlayerState { get }   // .idle .connecting .playing .stalled .failed(reason)
    func start()                          // idempotent
    func stop()                           // full teardown; safe to call twice
    var view: AnyView { get }             // player-owned render surface
}
```
`WebRTCLivePlayer` is the v1 conformer, `MJPEGLivePlayer` the fallback, and a future `MSELivePlayer`
slots in without touching call sites. The UI only ever sees `LivePlayer` + `LivePlayerState`. Each
player owns its own render surface because the surfaces are genuinely different (`RTCMTLVideoView`
vs an `Image`), which keeps the protocol from leaking Metal-layer details into SwiftUI code.

**Dependency.** One SPM package for libwebrtc. Prefer LiveKit's `WebRTC-SDK` (actively rebuilt,
production use, xcframework distribution); `stasel/WebRTC` is the fallback choice. Pin an exact
version - these are prebuilt binaries and a surprise bump can break the build in ways we can't
patch.

**Concurrency.** The WebSocket receive loop lives in an actor (`LiveSocket`) so the non-`Sendable`
`URLSessionWebSocketTask` never crosses isolation boundaries; signaling messages reach the
`@MainActor` player through an `AsyncStream`. `RTCPeerConnection` delegate callbacks arrive on
WebRTC's own threads and are hopped to the main actor explicitly.

**Grid stays snapshots.** No live streams in `CameraGridView` - the "never WebRTC a grid" rule,
already satisfied by the P2 snapshot loop.

---

## Chunk map

- **C1 - `LivePlayer` seam + live source resolution** (roadmap: "Define the `LivePlayer`
  interface"). Config parsing for `go2rtc.streams` / `live.streams`, the `LiveStreamSource`
  decision (WebRTC with a stream name / MJPEG fallback), the `LivePlayer` protocol + state enum,
  WebSocket URL and cookie plumbing on `FrigateClient`. No video yet. **Detailed below.**
- **C2 - WebRTC dependency + signaling.** Add the SPM package (pinned). `WebRTCSignaling`: connect
  the socket, exchange `webrtc/offer` -> `webrtc/answer`, trickle candidates both ways, surface
  connection-state transitions. Milestone: against the real server, a peer connection reaches
  `connected` and reports a selected candidate pair - proven by a unit test over a scripted
  message sequence plus a logged live run.
- **C3 - `WebRTCLivePlayer` + `LiveVideoView`.** `recvonly` transceivers, remote track handoff to
  `RTCMTLVideoView`, `LivePlayer` conformance, ICE/connection state mapped onto `LivePlayerState`.
  Milestone: a moving picture from a real camera on screen.
- **C4 - Wire into camera detail.** `LiveCameraView` shows the existing snapshot until the first
  frame renders (Frigate's own UX), then swaps to live; aspect-ratio handling, tap-to-fullscreen,
  and clear states for connecting / stalled / failed / unavailable. The snapshot poll stops once
  live is playing. Milestone: open a camera, watch it live.
- **C5 - Reconnect, fallback, teardown.** Exponential backoff on connection loss; an ICE-failure
  timeout that gives up and **falls back to the MJPEG player** rather than spinning forever
  (this is the chunk that makes objection #4 above survivable); teardown on `.onDisappear` /
  `scenePhase` background / tab switch; leak check (peer connection closed, socket closed, tasks
  cancelled). Milestone: kill wifi mid-stream and it recovers; block 8555 and it degrades to MJPEG
  with an explanatory note instead of hanging.
- **C6 - MJPEG fallback player.** `MJPEGLivePlayer` parses the `multipart/x-mixed-replace` boundary
  stream off a `URLSession.bytes` sequence and publishes frames through the same `LivePlayer` seam.
  Used for non-restreamed cameras and as C5's degradation target. Milestone: a camera with no
  go2rtc restream still shows motion.

_P4 milestone (all chunks): open a camera and watch it live, with automatic recovery after a
network blip and a graceful degradation path when WebRTC can't connect._

**Deferred to a later phase (documented, not built):** `MSELivePlayer` - the fMP4 demuxer described
above - as a tier-2 quality upgrade over MJPEG for users whose networks can't carry WebRTC. Audio
and two-way talk also stay out of P4.

---

## C1 - `LivePlayer` seam + live source resolution (FULL DETAIL)

No dependency yet, no video. Config + models + networking seams only, all unit-testable through the
existing `MockURLProtocol`.

### `Models/FrigateConfig.swift` (edit)

Two additive fields, both lenient (older/partial payloads must still decode - existing tests
construct configs without them):

```swift
let go2rtc: Go2RTCInfo          // decodeIfPresent -> .init(streams: [:])
struct Go2RTCInfo: Decodable, Equatable, Sendable {
    /// Only the KEYS matter. Values are string-or-array-of-string in real configs, so decode
    /// them as an opaque ignored value rather than trying to model go2rtc's source syntax.
    let streamNames: Set<String>
}
```
and inside `CameraConfig`:
```swift
let live: LiveInfo              // decodeIfPresent -> .init(streams: [])
struct LiveInfo: Decodable, Equatable, Sendable {
    let streams: [(label: String, name: String)]   // ordered; see gotcha below
}
```
**Ordering gotcha:** the PWA uses the *first* entry of `live.streams`, but Swift dictionaries are
unordered - JSON object order is lost through `[String: String]`. Decode through a custom
`init(from:)` that preserves declaration order, so "first stream" is faithful to the user's config
file rather than arbitrary. (`CameraConfig` already has a custom `init(from:)` to extend.)

### `Models/LiveStreamSource.swift` (new)

Pure decision logic - the one place that answers "how do I watch this camera?":

```swift
nonisolated enum LiveStreamSource: Equatable, Sendable {
    case webrtc(streamName: String)   // camera is restreamed through go2rtc
    case mjpeg(camera: String)        // no restream; low-res detect stream (C6)

    /// Mirrors the PWA: first configured live stream that is a known go2rtc stream wins.
    static func resolve(camera: String, config: FrigateConfig) -> LiveStreamSource
}
```
Rules, matching `use-camera-live-mode.ts`: take the first `live.streams` value; if it is a key of
`go2rtc.streams` -> `.webrtc(streamName:)`; otherwise `.mjpeg(camera:)`. A camera whose name is
itself a go2rtc stream key but has no `live.streams` mapping also resolves to `.webrtc` (common
single-stream setup, matching the PWA's `?? cameraName` default).

### `Features/Live/LivePlayer.swift` (new)

The protocol above plus:
```swift
nonisolated enum LivePlayerState: Equatable, Sendable {
    case idle, connecting, playing, stalled
    case failed(LivePlayerError)
}
nonisolated enum LivePlayerError: Equatable, Sendable {
    case signalingFailed          // couldn't reach or negotiate with go2rtc
    case iceFailed                // negotiated, but no candidate pair connected (port 8555)
    case connectionLost
    case notAvailable             // no live source for this camera
}
```
`iceFailed` is deliberately its own case: it is the one failure with a specific, explainable cause
("port 8555 isn't reachable from here"), it drives C5's fallback to MJPEG, and it is the thing to
say out loud in the UI rather than a generic error.

### `Networking/Endpoint.swift` (edit)

```swift
/// go2rtc WebRTC signaling socket. Off the server root (not `/api/`), like /clips/ and /vod/.
static func webrtcWebSocket(src: String) -> Endpoint   // "live/webrtc/api/ws", query src=…, basePath: nil

/// Low-res MJPEG stream from the detect feed (C6 fallback).
static func mjpegStream(camera: String, fps: Int = 5, height: Int = 720) -> Endpoint
```

### `Networking/FrigateClient.swift` (edit)

```swift
/// Same URL composition as every other endpoint, with the scheme mapped http->ws / https->wss.
func webSocketURL(for endpoint: Endpoint) -> URL?

/// A connected WebSocket, created from the client's own URLSession so it inherits the cookie jar
/// and the insecure-trust delegate. The `frigate_token` cookie is also set explicitly on the
/// handshake request (nginx `auth_request` gates this route).
func liveSocket(for endpoint: Endpoint) throws -> LiveSocket
```
`LiveSocket` is a small actor wrapping `URLSessionWebSocketTask` (`send(_:)`, an
`AsyncStream<Message>` of received frames, `close()`), so the non-`Sendable` task never escapes.

### Tests (`FrigateTests`)

- **`FrigateConfigTests`** (extend) - a payload with `go2rtc.streams` + per-camera `live.streams`
  decodes; a payload with neither still decodes (no regression for existing fixtures); go2rtc
  stream values that are strings *and* arrays both decode without throwing; `live.streams` order
  is preserved.
- **`LiveStreamSourceTests`** (new) - restreamed camera -> `.webrtc` with the first mapped stream
  name; unmapped camera -> `.mjpeg`; camera name matching a go2rtc key with no mapping ->
  `.webrtc`; multi-stream camera picks the first as configured, not alphabetically.
- **`EndpointTests`** (extend) - `.webrtcWebSocket(src:)` -> `{base}/live/webrtc/api/ws?src=front`
  with **no** `api/` prefix; `.mjpegStream(...)` -> `{base}/api/front?fps=5&height=720`.
- **`FrigateClientTests`** (extend) - `webSocketURL` maps `http`->`ws` and `https`->`wss` and keeps
  host/port/path/query; existing `authedURL` behavior unchanged.

### Out of scope for C1 (explicit)

No SPM dependency, no peer connection, no UI, no reconnect policy. C1 proves only: we can tell how
a given camera should be watched, and we can open an authenticated socket to the right URL.

---

## Risks

- **ICE reachability is the risk that decides P4's real-world success.** Mitigation is structural,
  not hopeful: C5's fallback to MJPEG means an unreachable 8555 degrades instead of hanging, and
  `LivePlayerError.iceFailed` gives the UI something true to say. Verify early - C2's milestone is
  a real connected candidate pair against the real server, not a green unit test.
- **Binary dependency.** Pin the exact libwebrtc version; check app size impact when it lands
  (a ~30MB xcframework is the single biggest thing in the app) and confirm bitcode/arm64-simulator
  slices work under Xcode 26 before building C3 on top of it.
- **Deferred MSE means a reach gap** for users behind UDP/TCP-hostile tunnels: they get MJPEG
  quality, not real video. Accepted deliberately, documented in the ADR, and revisitable as a
  self-contained chunk - the `LivePlayer` seam is what keeps that cheap.
- **Carry-over from P3:** clip playback (`ClipPlayerView`) has still never been smoke-tested
  against a real server on a device. The first P4 device session should verify it in the same
  sitting - it exercises the same cookie-auth-for-media assumption this phase leans on.

## Out of scope for P4

Audio, two-way talk, PTZ, live in the grid, recordings scrubbing, picture-in-picture, multi-stream
quality switching, and the MSE demuxer. All later phases.

## Verification

Per chunk: `xcodebuild -project "app/Frigate.xcodeproj" -scheme Frigate -destination 'platform=iOS
Simulator,name=iPhone 17' test` stays green (105 tests today).

End-to-end (needs the real server, and a physical device for the honest latency/battery read):
open a camera -> still image appears immediately -> live video takes over within a couple of
seconds -> leave it running five minutes without stalling -> drop wifi and watch it reconnect ->
background the app and confirm the peer connection closes -> block port 8555 (or test from a
network that can't reach it) and confirm the MJPEG fallback engages with a clear explanation ->
open a non-restreamed camera and confirm the same fallback.

## Docs to update as we go

- `docs/ROADMAP.md` - rewrite the P4 bullets around WebRTC + MJPEG; flip statuses per chunk.
- `docs/DECISIONS.md` - an ADR recording that Frigate exposes **no live HLS** (the finding that
  invalidates the original plan), why WebRTC + MJPEG was chosen over building an fMP4 demuxer, and
  the conditions under which we'd revisit MSE.
- `CLAUDE.md` - amend the two rules this finding invalidates: "ship `HLSPlayer` only for v1" and
  "low-res HLS for the grid" (grid stays on snapshots).
- `docs/LEARNINGS.md` - ICE/candidate gotchas, whether the WS handshake really carries the cookie,
  and what the app-size hit actually was.
