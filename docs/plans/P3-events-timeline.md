# P3 - Events Timeline

## Context

P1 (connect/authenticate) and P2 (camera grid) are done: the app connects to a Frigate server,
authenticates (cookie session with silent 401 re-login), persists the server, and shows a live
grid of camera snapshots. `FrigateClient` (actor) is the single HTTP entry point; feature code
builds an `Endpoint` and calls typed methods. The Events tab is still `EventsPlaceholderView`.

P3 makes the second tab real: **browse what happened on your cameras and play the clip.** Per the
roadmap milestone - _"browse events and play their clips."_

This plan defines the **full P3 architecture**, breaks P3 into **6 individually-plannable chunks
(C1-C6)**, and **fully details C1 (the review data layer)**. C2-C6 are outlined here as
one-paragraph summaries and will each get their own `/plan` session when we start them.

Branch: `P3-Events-Timeline` (create off `main` when starting C1; current branch is `P2-Camera-Grid`).

### Decision locked with the user: build on `/api/review`, not `/api/events`

Frigate exposes two list endpoints and its own PWA uses both, for different screens:

- **`/api/review`** backs the PWA's default **Review** timeline - activity **segments** grouped
  and tagged `severity: alert | detection`, each with a reviewed/unreviewed state. This is the
  "what happened" NVR view.
- **`/api/events`** backs the PWA's **Explore/search** view and supplies all per-object media
  (`/api/events/{id}/thumbnail.webp|snapshot.jpg|clip.mp4`).

**We surface review segments** - they carry the actual metrics of what happened (objects, zones,
severity, time span, reviewed-state) and read like an NVR rather than a raw object dump. `/api/events`
is deferred to a later phase (per-object drill-down / search), if ever. Where P3 needs an
object-level still we can still reach into a segment's `data.detections` (which are event ids), but
the primary list, thumbnails, and clips all come from the review side.

### Verified Frigate API facts (read directly from `~/Documents/frigate`)

**List endpoint** - `GET /api/review` (`frigate/api/review.py:45`,
`allow_any_authenticated`). Query params (`ReviewQueryParams`,
`frigate/api/defs/query/review_query_parameters.py`):

| param | default | notes |
|---|---|---|
| `cameras` | `"all"` | comma-joined camera names |
| `labels` | `"all"` | comma-joined; matches `data.objects` / `data.audio` |
| `zones` | `"all"` | comma-joined; matches `data.zones` |
| `severity` | none | `alert` \| `detection`; **omit to get both** |
| `reviewed` | none | `0` = unreviewed only, `1` = reviewed only, omit = both |
| `before` | `now` | unix seconds (float) |
| `after` | `now - 24h` | unix seconds (float) |
| `limit` | none | max rows |

- **Windowing gotcha (matters for pagination, C6):** if you pass `before` but omit `after`,
  the server still defaults `after` to `now - 24h` - so a "load older" cursor that only moves
  `before` backward will return nothing past 24h ago. **Always send both `before` and `after`
  explicitly when paging.**
- **Ordering:** `severity ASC, start_time DESC` (alerts before detections within the window, then
  newest first). We will re-sort/segment client-side for a purely chronological or grouped view.

**Response** - `list[ReviewSegmentResponse]` (`frigate/api/defs/response/review_response.py`;
values come straight from the DB via `.dicts()`):

```
id: String
camera: String
start_time: Double            # unix seconds. Annotated `datetime` in the response model but the
end_time: Double | null       # DB stores epoch floats (like the PWA's numeric handling). end_time
                              # is null while the segment is still in progress.
severity: "alert" | "detection"
has_been_reviewed: Bool       # per-user (joined on the JWT's username)
thumb_path: String            # server filesystem path, e.g.
                              #   /media/frigate/clips/review/thumb-<camera>-<id>.webp
data: {
  detections: [String]        # tracked-object (event) ids in this segment
  objects:    [String]        # labels, e.g. ["person","car"]
  sub_labels: [String]
  zones:      [String]
  audio:      [String]
  thumb_time: Double | null
  ...                         # verified_objects, metadata - ignored
}
```

**Thumbnail image** - there is **no** `/api/review/{id}/thumbnail`. The PWA renders the segment
thumb by transforming `thumb_path`: strip the leading `/media/frigate/` and request the remainder
off the server root - `GET {base}/clips/review/thumb-<camera>-<id>.webp`
(`web/src/components/card/ReviewCard.tsx:168`). That path is served by nginx `location /clips/`
**behind `auth_request`** (cookie auth applies) and is **not under `/api/`**
(`docker/main/rootfs/.../nginx.conf:149`). => the client must be able to address a base-relative
path that skips the `api/` prefix (see C1 `Endpoint.basePath`).

**Animated preview** (optional, C4) - `GET /api/review/{id}/preview?format=gif|mp4`
(`frigate/api/media.py:1649`), an 8s-padded scrubbable preview of the segment.

**Clip** - `GET /api/review/{id}/clip.mp4` (`frigate/api/media.py:1240`) delegates to
`recording_clip`, which streams a **fragmented mp4** (`-movflags frag_keyframe+empty_moov`,
`media.py:443`). The route's own description says: _"For iOS devices, use the master.m3u8 HLS link
instead of clip.mp4. Safari does not reliably process progressive mp4 files."_ The HLS equivalent
is `GET {base}/vod/{camera}/start/{start_ts}/end/{end_ts}/master.m3u8` (`media.py:552`), also
cookie-authed and **not under `/api/`**. This shapes C5 - see there.

**Mark reviewed** (C4) - `POST /api/reviews/viewed` body `{"ids":[...], "reviewed": true|false}`
(`review.py:477`); un-review a single one with `DELETE /api/review/{id}/viewed` (`review.py:706`).

**Summary / filter options** (optional, C3) - `GET /api/review/summary` returns per-day and
last-24h counts of reviewed/total alerts & detections; useful for badges but not required for v1.

### Decisions locked with the user

1. **This plan** = architecture overview + C1-C6 map, with **C1 fully detailed**; C2-C6 get their
   own plans later (same shape as the P1 plan).
2. **Source = `/api/review`** (segments), not `/api/events`.
3. Everything reuses the existing `FrigateClient` cookie-auth path; snapshots/thumbnails/clips get
   the same silent 401 re-login + retry as JSON.

---

## Architecture overview

Everything lands under `app/Frigate/Features/Events/` plus small additions to `Models/` and
`Networking/`. Nothing in the existing connect/auth/camera layers changes except two additive
seams on `Endpoint`/`FrigateClient` (base-relative paths, a clip URL builder).

```
app/Frigate/
  Models/
    ReviewSegment.swift         Codable segment + severity + nested data          [C1]
  Networking/
    Endpoint.swift    (edit)    add `basePath` so paths can skip `api/`;          [C1]
                                add .review(...), .reviewThumbnail(...), .reviewClip(...)
    FrigateClient.swift (edit)  fetchReviews(...), reviewThumbnail(...),          [C1]
                                authedURL(for:) for AVPlayer
  Features/Events/
    EventsView.swift            list of review cards, grouped by day              [C2]
    EventsModel.swift           @Observable: load, paginate, filter, mark-read    [C2/C3/C6]
    ReviewCardView.swift        one row: thumbnail + severity + camera + objects  [C2]
    ReviewThumbnail.swift       async cookie-authed image loader (reusable)       [C2]
    EventFilters.swift          value type: cameras/labels/severity/timeRange     [C3]
    EventFilterSheet.swift      filter UI                                         [C3]
    ReviewDetailView.swift      big thumbnail + metadata + mark-reviewed + Play   [C4]
    ReviewDetailModel.swift     @Observable detail state                          [C4]
    ClipPlayerView.swift        AVPlayer wrapper for the segment clip             [C5]
```

**Layers and seams:**

- **`ReviewSegment` (Codable value type)** - the decoded `/api/review` row plus computed helpers
  (`title`, `objectSummary`, `duration`, `isInProgress`, `thumbnailPath`). One model reused by the
  list, detail, and clip screens.
- **`EventsModel` (@Observable, @MainActor)** - owns the timeline: the current `EventFilters`, the
  loaded `[ReviewSegment]`, load/refresh/paginate, and mark-reviewed. Mirrors the shape of
  `CameraGridModel` (a `client` + async loads) but paginated and filtered rather than
  timer-refreshed. This is the one place that talks to `FrigateClient` for events.
- **`Endpoint.basePath`** - today `makeRequest` hardcodes `baseURL/api/<path>`. Generalize to an
  optional `basePath` (default `"api"`, `nil` = address off the server root) so review thumbnails
  (`/clips/...`) and the HLS VOD manifest (`/vod/...`) are first-class `Endpoint`s that still flow
  through the same auth/retry code. Backward compatible - existing endpoints keep `basePath: "api"`.
- **`FrigateClient.authedURL(for:)`** - builds the fully-resolved `URL` for a base-relative
  endpoint so `AVPlayer` can stream it. Auth is by cookie; the cookie jar is the shared
  App-Group `HTTPCookieStorage`, so `AVURLAsset` must be handed the `frigate_token` cookie
  explicitly (`AVURLAssetHTTPCookiesKey`) - AVFoundation does not read that jar automatically.
  This helper + cookie extraction is the C5 seam.
- **`ReviewThumbnail`** - a small `AsyncImage`-like view that fetches webp bytes via
  `client.reviewThumbnail(...)` (so it gets 401-retry and the insecure-trust delegate) and caches
  the decoded image. Reused by the card and the detail header.

**Concurrency:** `FrigateClient` stays an `actor`; the new methods are just more `Endpoint`s
through the existing `send`/`data(for:)`. View models are `@MainActor @Observable`, like the P2
camera models.

---

## Chunk map (C1-C6)

Each maps to a P3 roadmap bullet and ends at a provable milestone.

- **C1 - Review data layer** (roadmap: "Fetch event/review list with thumbnails", data half).
  `ReviewSegment` model, `Endpoint` `basePath` generalization + review builders, `FrigateClient`
  `fetchReviews`/`reviewThumbnail`/`authedURL`. Networking + decoding only, no UI. Milestone:
  `xcodebuild test` green - decode a real `/api/review` payload, build the correct thumbnail/clip
  URLs, map the `/media/frigate/` -> `/clips/` transform. **Detailed below.**
- **C2 - Timeline list UI** (roadmap: "...with thumbnails", UI half). `EventsView` replaces the
  placeholder: a scrollable list of `ReviewCardView` rows (thumbnail, severity chip, camera, object
  summary, relative time), grouped by day, with loading/empty/error states and pull-to-refresh.
  `EventsModel` does the initial 24h load. Milestone: open the Events tab and see your real recent
  activity with thumbnails.
- **C3 - Filters** (roadmap: "Filters (camera, label, time range)"). `EventFilters` value type +
  `EventFilterSheet`; wire into `EventsModel` -> `.review(...)` query (`cameras`, `labels`,
  `severity`, `before`/`after`). Camera options from `config.enabledCameraNames`; label options
  derived from loaded segments' `data.objects` (v1) - optionally `/api/review/summary` later.
  Milestone: filter the timeline by camera, label/severity, and a time range; result set updates.
- **C4 - Review detail + mark-reviewed** (roadmap: "Event detail screen (snapshot)").
  `ReviewDetailView`: large thumbnail (`thumb_path`), metadata (camera, severity, time span,
  objects, zones), and a "mark reviewed / unreviewed" toggle (`POST /api/reviews/viewed` /
  `DELETE .../viewed`) that reflects back into the list. A "Play clip" button routes to C5.
  Milestone: tap a segment, see its details, toggle reviewed, and it sticks in the list.
- **C5 - Clip playback via AVPlayer** (roadmap: "Clip playback via AVPlayer (mp4 - the easy
  video)"). `ClipPlayerView` wraps `AVPlayer`. **Playback source decision (documented, verify on
  device):** start with the fragmented `clip.mp4` (`/api/review/{id}/clip.mp4`) - single URL,
  matches the roadmap's "easy video" - and fall back to the HLS `master.m3u8` VOD manifest that
  Frigate recommends for iOS if progressive playback stalls/fails on a real device. Either way the
  `frigate_token` cookie is injected via `AVURLAssetHTTPCookiesKey` (see architecture). Milestone:
  play a segment's clip full-screen with working controls; clean teardown on dismiss.
- **C6 - Pagination / infinite scroll** (roadmap: "Pagination / infinite scroll"). `EventsModel`
  loads pages of `limit` N; the "load older" cursor moves **both** `before` (to the oldest loaded
  `start_time`) **and** `after` (a window floor) to dodge the 24h default-`after` trap. Infinite
  scroll appends as the last row appears; de-dupe on `id`; guard against concurrent loads.
  Milestone: scroll back through days of activity smoothly, past the initial 24h window.

_P3 milestone (all chunks): open Events, browse real activity with thumbnails, filter it, open a
segment, and play its clip._

---

## C1 - Review data layer (FULL DETAIL)

Networking + models only. No UI. Everything is unit-testable via the existing `MockURLProtocol`
and an injected `URLSession`, exactly like the P1/P2 client tests.

### Files to create / edit (under `app/Frigate/`)

**`Models/ReviewSegment.swift`** (new) - the decoded row plus display helpers.
```swift
nonisolated struct ReviewSegment: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let camera: String
    let startTime: Double          // unix seconds
    let endTime: Double?           // nil while in progress
    let severity: Severity
    let hasBeenReviewed: Bool
    let thumbPath: String          // raw server path from the API
    let data: ReviewData

    enum Severity: String, Decodable, Sendable, Equatable, CaseIterable {
        case alert, detection
        // Unknown/future severities decode leniently rather than failing the whole list.
    }

    struct ReviewData: Decodable, Equatable, Sendable {
        let detections: [String]   // event ids
        let objects: [String]      // labels
        let subLabels: [String]
        let zones: [String]
        let audio: [String]

        enum CodingKeys: String, CodingKey {
            case detections, objects, zones, audio
            case subLabels = "sub_labels"
        }
        // All fields decodeIfPresent -> [] so partial/old payloads still decode.
    }

    enum CodingKeys: String, CodingKey {
        case id, camera, severity, data
        case startTime = "start_time"
        case endTime = "end_time"
        case hasBeenReviewed = "has_been_reviewed"
        case thumbPath = "thumb_path"
    }

    // Display helpers (no server calls):
    var isInProgress: Bool { endTime == nil }
    var duration: TimeInterval? { endTime.map { $0 - startTime } }
    /// Server-root-relative thumbnail path: strip the "/media/frigate/" prefix so it can be
    /// requested off `{base}/clips/...`. Falls back to the raw path if the prefix is absent.
    var thumbnailPath: String {
        thumbPath.hasPrefix("/media/frigate/")
            ? String(thumbPath.dropFirst("/media/frigate/".count))
            : thumbPath.trimmingPrefix("/")   // never send a leading slash to Endpoint
    }
    /// e.g. "Person, Car" - title-cased unique objects; falls back to severity if empty.
    var objectSummary: String { ... }
}
```
- **Severity leniency:** decode via `Severity(rawValue:) ?? .detection` in a custom `init(from:)`
  (or a `@unknown`-safe wrapper) so a new server severity never drops the whole page.
- `startTime`/`endTime` are `Double` unix seconds. **To verify against a live server** (belt and
  suspenders, since the response model annotates `datetime`): confirm the JSON is numeric, not an
  ISO string. If any server returns ISO, add a decoder that accepts both. Design assumes numeric
  (matches the PWA and the events endpoint).

**`Networking/Endpoint.swift`** (edit) - generalize the base prefix and add review builders.
- Add a field: `var basePath: String? = "api"`. `nil` addresses the server root (for `/clips/`,
  `/vod/`).
- Builders:
  ```swift
  static func review(cameras: [String] = [], labels: [String] = [],
                     severity: ReviewSegment.Severity? = nil,
                     before: Double? = nil, after: Double? = nil,
                     limit: Int? = nil) -> Endpoint
  // path "review"; query joins non-empty lists with ","; omits params left at "all"/nil.

  static func reviewThumbnail(path: String) -> Endpoint
  // Endpoint(path: path, basePath: nil)  -> {base}/clips/review/thumb-....webp

  static func reviewClip(id: String) -> Endpoint
  // Endpoint(path: "review/\(id)/clip.mp4")  (under api/)

  static func reviewClipHLS(camera: String, start: Double, end: Double) -> Endpoint
  // Endpoint(path: "vod/\(camera)/start/\(start)/end/\(end)/master.m3u8", basePath: nil)
  ```

**`Networking/FrigateClient.swift`** (edit) - typed conveniences + a URL builder for AVPlayer.
- Update `makeRequest` to honor `basePath`:
  ```swift
  let root = endpoint.basePath.map { baseURL.appending(path: $0) } ?? baseURL
  let fullURL = root.appending(path: endpoint.path)
  ```
  (Behavior unchanged for existing `basePath == "api"` endpoints.)
- Conveniences:
  ```swift
  func fetchReviews(cameras: [String] = [], labels: [String] = [],
                    severity: ReviewSegment.Severity? = nil,
                    before: Double? = nil, after: Double? = nil,
                    limit: Int? = nil) async throws -> [ReviewSegment]
      // send(.review(...))  -> decodes [ReviewSegment]

  func reviewThumbnail(path: String) async throws -> Data   // data(for: .reviewThumbnail(path:))
  ```
- **AVPlayer URL seam** (used by C5, defined here so the plumbing is one place):
  ```swift
  /// Fully-resolved URL for a base-relative endpoint, for handing to AVPlayer/AVURLAsset.
  func authedURL(for endpoint: Endpoint) -> URL?
  /// The current frigate_token cookie (from the shared jar), so AVURLAsset can be given
  /// AVURLAssetHTTPCookiesKey. AVFoundation does not consult URLSession's cookie jar itself.
  func sessionCookies(for url: URL) -> [HTTPCookie]
  ```

### Tests (`FrigateTests`)

- **`ReviewSegmentTests`** - decode a canned `/api/review` payload (2-3 segments, one alert with
  `end_time: null` in-progress, one detection): assert `id/camera/severity/startTime/endTime`,
  `data.objects/zones`, `hasBeenReviewed`. Unknown severity string -> `.detection` (no throw).
  Missing `data` sub-arrays -> `[]`. `thumbnailPath` strips `/media/frigate/`.
- **`EndpointTests`** (extend) - `.review(...)` URL: `.../api/review?cameras=a,b&labels=person&severity=alert&before=..&after=..&limit=100`; params omitted when empty/nil.
  `.reviewThumbnail(path:)` -> `{base}/clips/review/thumb-x.webp` (**no** `api/`).
  `.reviewClipHLS(...)` -> `{base}/vod/cam/start/../end/../master.m3u8` (**no** `api/`).
  Existing `api/`-prefixed endpoints unchanged.
- **`FrigateClientTests`** (extend) - `fetchReviews` decodes the list off `MockURLProtocol`;
  a `401` then `200` with a stub provider retries once and succeeds (reuses the existing seam);
  `reviewThumbnail` returns raw bytes for a non-`api/` path; `authedURL` composes the right
  base-relative URL.

### Out of scope for C1 (explicit)

No UI, no filters, no pagination cursor logic, no AVPlayer, no mark-reviewed mutation (C4). C1 only
proves: decode segments, build every URL shape (list, thumbnail, clip, HLS), and reach thumbnails
through the auth/retry path.

---

## C2 - Timeline list UI (SUMMARY)

`EventsView` (replaces `EventsPlaceholderView`, wired in `MainTabView` with the `client` + config)
renders `EventsModel.segments` as a `List`/`LazyVStack` of `ReviewCardView` rows grouped by day
(`Section` per calendar day). Each row: `ReviewThumbnail` (cookie-authed webp loader), a severity
chip (alert = accent/red, detection = muted), camera name, `objectSummary`, relative start time,
and an "unreviewed" dot. States: `.loading` (skeletons), `.empty` (`ContentUnavailableView`),
`.failed` (retry). Pull-to-refresh reloads the newest window. `EventsModel.load()` does the initial
`fetchReviews(after: now-24h, before: now)`. Milestone: real activity with thumbnails on the Events
tab.

## C3 - Filters (SUMMARY)

`EventFilters` value type (`cameras: Set<String>`, `labels: Set<String>`, `severity: Severity?`,
`timeRange`) drives the `fetchReviews` query. `EventFilterSheet` (toolbar filter button):
camera multi-select from `config.enabledCameraNames`, label multi-select from the union of loaded
`data.objects` (v1; `/api/review/summary` can enrich later), severity segmented
(All/Alerts/Detections), and a time-range picker (Last 24h / Today / Last 7 days / custom). Changing
filters re-runs the query from the top. Milestone: filter by camera, label/severity, time range.

## C4 - Review detail + mark-reviewed (SUMMARY)

`ReviewDetailView` (push from a card tap): large `thumb_path` image (optionally the animated
`preview?format=gif`), metadata rows (camera, severity, start-end span + duration, objects, zones),
a "Mark reviewed"/"Mark unreviewed" toggle backed by `POST /api/reviews/viewed` /
`DELETE /api/review/{id}/viewed` that updates the segment in the shared list, and a prominent
"Play clip" button -> C5. `ReviewDetailModel` owns the mutation + optimistic UI. Milestone: open a
segment, read its details, toggle reviewed and have it persist in the list.

## C5 - Clip playback via AVPlayer (SUMMARY)

`ClipPlayerView` wraps `AVPlayer` in a `VideoPlayer`/`UIViewControllerRepresentable`. Source
(decided during C5, **verify on a physical device**): try the fragmented `clip.mp4`
(`.reviewClip(id:)`) first; if progressive playback is unreliable on device, switch to the HLS
`master.m3u8` VOD manifest Frigate recommends for iOS (`.reviewClipHLS(...)`). Build the asset with
`AVURLAsset(url:options:)` passing `AVURLAssetHTTPCookiesKey: client.sessionCookies(for:)` so the
`frigate_token` cookie authenticates the stream (AVFoundation ignores URLSession's jar). Handle
loading/failed states and tear the player down on dismiss (pause, nil the item). This deliberately
does **not** touch the P4 `LivePlayer` interface - clips are VOD, live is a later, separate seam.
Milestone: full-screen clip playback with controls and clean teardown.

## C6 - Pagination / infinite scroll (SUMMARY)

`EventsModel` paginates: each page `fetchReviews(before: cursor, after: windowFloor, limit: N)`.
The cursor starts at `now`; "load older" sets `before = segments.last.startTime` and moves `after`
back by the page window (e.g. `before - 7d`) - **both** must be sent or the server re-defaults
`after` to `now-24h` and returns nothing older. Append with `id` de-dupe, a `isLoadingPage` guard
against concurrent loads, and an `.onAppear` trigger on the last row. Stop when a page returns fewer
than `N`. Milestone: scroll back through days of activity past the initial 24h window.

---

## Verification

**C1 (this chunk):** unit tests, no server:
```bash
xcodebuild -project "app/Frigate.xcodeproj" -scheme Frigate \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```
Expect the new `ReviewSegment`/review-endpoint/thumbnail tests to pass alongside the existing 64.
Optional live smoke: from a scratch call, `fetchReviews()` against the real server
(`frigate.sagarp.ca`) and print the first few segments to confirm real-world decode (esp. the
numeric-vs-ISO timestamp question) and that a `thumbnailPath` fetch returns webp bytes.

**P3 end-to-end (after C6):** on a device/simulator against a real Frigate - open Events and see
recent segments with thumbnails; filter by camera/label/severity/time; open a segment, read
metadata, toggle reviewed (verify it sticks); play the clip full-screen; scroll back past 24h.

## Docs to update as we go

- `docs/ROADMAP.md`: flip P3 items to in-progress/done as each chunk lands.
- `docs/DECISIONS.md`: record the review-vs-events choice (surface segments, not raw objects) and
  the clip-source decision (fragmented mp4 first, HLS VOD fallback for iOS) once C5 settles it.
- `docs/LEARNINGS.md`: capture gotchas as they surface - the `after` default-window trap, the
  `/media/frigate/` -> `/clips/` thumbnail transform, AVPlayer needing the cookie via
  `AVURLAssetHTTPCookiesKey`, and whether real servers return numeric or ISO review timestamps.
```
