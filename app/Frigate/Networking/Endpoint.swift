import Foundation

/// A declarative description of one Frigate HTTP request. `path` is relative to `<baseURL>/api/`
/// (e.g. `"config"`, `"login"`). Adding a new API is a matter of adding one builder here plus a
/// `Codable` model.
nonisolated struct Endpoint: Sendable {
    var path: String
    var method: HTTPMethod = .get
    var query: [URLQueryItem] = []
    var body: Data? = nil
    var headers: [String: String] = [:]
    /// Prefix joined between `baseURL` and `path`. Defaults to `"api"`. `nil` addresses the
    /// server root - needed for the handful of routes that live outside `/api/` (review
    /// thumbnails under `/clips/`, HLS manifests under `/vod/`).
    var basePath: String? = "api"
}

nonisolated extension Endpoint {
    static var config: Endpoint {
        Endpoint(path: "config")
    }

    static func login(_ body: LoginRequest) throws -> Endpoint {
        let data = try JSONEncoder().encode(body)
        return Endpoint(
            path: "login",
            method: .post,
            body: data,
            headers: ["Content-Type": "application/json"]
        )
    }

    /// The latest decoded frame for a camera, falling back server-side to the most recent preview
    /// frame (or an error placeholder image) if the camera is offline. The server still returns a
    /// non-200 (400 invalid params, 404 unknown camera, 500 no frame available) in some cases, so
    /// callers must handle failure, not assume an image always comes back.
    /// `height` resizes server-side (query key is `height`, not the `h` a couple of PWA call sites
    /// use - those are silently ignored by the server and serve full size).
    static func snapshot(camera: String, height: Int? = nil) -> Endpoint {
        var query: [URLQueryItem] = []
        if let height {
            query.append(URLQueryItem(name: "height", value: String(height)))
        }
        return Endpoint(path: "\(camera)/latest.jpg", query: query)
    }

    /// Activity segments. Empty filter lists are omitted so the server applies its own "all"
    /// default; `before`/`after` should both be passed together when paging (see C6) since the
    /// server re-defaults a missing `after` to "24h before now", not "no lower bound".
    ///
    /// `reviewed` maps to the server's integer flag: `false` -> `reviewed=0` (only segments the
    /// current user hasn't marked reviewed) and `true` -> `reviewed=1` (only ones they have).
    /// Omitted entirely when `nil`, which is the server's "no filter" case - note that's a third
    /// state, not the same as `0`.
    static func review(
        cameras: [String] = [],
        labels: [String] = [],
        severity: ReviewSegment.Severity? = nil,
        before: Double? = nil,
        after: Double? = nil,
        limit: Int? = nil,
        reviewed: Bool? = nil
    ) -> Endpoint {
        var query: [URLQueryItem] = []
        if !cameras.isEmpty {
            query.append(URLQueryItem(name: "cameras", value: cameras.joined(separator: ",")))
        }
        if !labels.isEmpty {
            query.append(URLQueryItem(name: "labels", value: labels.joined(separator: ",")))
        }
        if let severity {
            query.append(URLQueryItem(name: "severity", value: severity.rawValue))
        }
        if let before {
            query.append(URLQueryItem(name: "before", value: String(before)))
        }
        if let after {
            query.append(URLQueryItem(name: "after", value: String(after)))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let reviewed {
            query.append(URLQueryItem(name: "reviewed", value: reviewed ? "1" : "0"))
        }
        return Endpoint(path: "review", query: query)
    }

    /// A review segment's thumbnail, off the server root (not `/api/`). `path` is
    /// `ReviewSegment.thumbnailPath`, e.g. `"clips/review/thumb-front_door-<id>.webp"`.
    static func reviewThumbnail(path: String) -> Endpoint {
        Endpoint(path: path, basePath: nil)
    }

    static func reviewClip(id: String) -> Endpoint {
        Endpoint(path: "review/\(id)/clip.mp4")
    }

    /// The server-rendered preview clip for a review segment: a low-resolution (180px tall)
    /// MP4 covering the segment's span plus 8s of padding either side.
    ///
    /// Usable where `reviewClip` isn't. Frigate renders this one to a file on disk and hands it to
    /// nginx via `X-Accel-Redirect`, so it arrives with a `Content-Length` and honours Range -
    /// AVPlayer can determine its duration and loop it. `clip.mp4` is piped live from ffmpeg with
    /// neither, which is why `ClipPlayerView` has to go through the HLS VOD manifest instead.
    ///
    /// The server has *already* compressed time by ~8.33x when generating this (it re-times the
    /// 1-2fps preview frames to 8fps), so play it at rate 1.0 - speeding it up further is what the
    /// PWA does to the raw hourly preview files, a different source entirely.
    ///
    /// Returns 404 when no preview file covers the segment's time range (preview generation
    /// disabled, or the recording aged out), so callers must degrade gracefully rather than
    /// assume a video always comes back.
    static func reviewPreviewMP4(id: String) -> Endpoint {
        Endpoint(path: "review/\(id)/preview", query: [URLQueryItem(name: "format", value: "mp4")])
    }

    /// Marks one review segment reviewed/unreviewed. Body shape matches the server's
    /// `ReviewModifyMultipleBody` (a list, even for a single id). Note the path is `reviews`
    /// (plural) - unlike every other route here, which is singular `review/...`; that's genuinely
    /// how the server mounts this one, not a typo.
    static func setReviewed(id: String, reviewed: Bool) throws -> Endpoint {
        let data = try JSONEncoder().encode(SetReviewedRequest(ids: [id], reviewed: reviewed))
        return Endpoint(
            path: "reviews/viewed",
            method: .post,
            body: data,
            headers: ["Content-Type": "application/json"]
        )
    }

    /// HLS VOD manifest for a segment's camera/time range - the source Frigate recommends for
    /// iOS playback over the progressive `clip.mp4`. Off the server root, not `/api/`.
    static func reviewClipHLS(camera: String, start: Double, end: Double) -> Endpoint {
        Endpoint(path: "vod/\(camera)/start/\(start)/end/\(end)/master.m3u8", basePath: nil)
    }
}
