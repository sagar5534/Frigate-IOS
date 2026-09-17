import Foundation

/// One way of watching a camera live.
///
/// All three tiers of the ladder (ADR-012): each is one `LivePlayer` conformer plus one case in
/// `LivePlayerFactory`, and `LiveCameraModel` walks down the ladder when a tier fails.
nonisolated enum LiveTransport: Equatable, Sendable {
    /// go2rtc WebRTC. Sub-second, but its media rides port 8555 rather than the HTTPS origin.
    /// `streamName` is the **go2rtc stream name**, which is not always the camera name.
    case webrtc(streamName: String)
    /// go2rtc MSE (fMP4 over WebSocket): real H.264/H.265 at ~1-2s over the same authenticated
    /// HTTPS origin, so it works where WebRTC's port-8555 media path can't cross. **P4.1.**
    case mse(streamName: String)
    /// Frigate's own MJPEG feed off the low-res detect stream. Works anywhere, for every camera -
    /// including ones with no go2rtc restream at all. **P4.2.**
    ///
    /// `height`/`fps` ride along because the server re-encodes JPEGs *per connected client* at
    /// whatever is asked: values above the detect stream's own resolution or rate buy nothing and
    /// cost real server CPU, so they are clamped to the camera's detect config where the config is
    /// at hand - at ladder-resolution time, not in the player.
    case mjpeg(camera: String, height: Int, fps: Int)
}

/// Answers the one question "how do I watch this camera?", as pure functions over the config.
nonisolated enum LiveStreamSource {
    /// The ordered preference ladder for a camera, best rung first.
    ///
    /// A camera is *restreamed* when one of its `live.streams` values names a real `go2rtc.streams`
    /// entry (`restreamedStreamName` below picks which one, and differs from the PWA's rule for
    /// reasons documented there). Restreamed cameras can use every tier; the rest can only use
    /// MJPEG, which is why P4.2 is what finally makes live view work for every camera rather than
    /// most.
    static func ladder(camera: String, config: FrigateConfig) -> [LiveTransport] {
        let mjpeg = mjpegRung(camera: camera, config: config)
        guard let streamName = restreamedStreamName(camera: camera, config: config) else {
            return [mjpeg]
        }
        return [
            .webrtc(streamName: streamName),
            .mse(streamName: streamName),
            mjpeg,
        ]
    }

    /// MJPEG frames come from the detect stream, so asking for more height or rate than detect has
    /// only makes the server upscale and duplicate - per connected client. Clamp to the detect
    /// config, capped at what a phone screen meaningfully shows.
    private static func mjpegRung(camera: String, config: FrigateConfig) -> LiveTransport {
        let detect = config.cameras[camera]?.detect ?? .init()
        return .mjpeg(
            camera: camera,
            height: min(detect.height ?? 720, 720),
            fps: min(detect.fps, 5)
        )
    }

    /// The go2rtc stream backing this camera, or `nil` when it isn't restreamed.
    ///
    /// The PWA takes the *first* `live.streams` entry, meaning the user's declaration order. We
    /// cannot: JSON object order does not survive `JSONDecoder`, and reading keys in their natural
    /// (hash) order would pick a different stream on every launch (see `FrigateConfig.LiveInfo`).
    /// So the rule here is deterministic and, where it can be, meaningful:
    ///
    /// 1. Only streams that actually exist in `go2rtc.streams` are candidates. A `live.streams`
    ///    value naming a nonexistent stream reaches us intact - the server's own
    ///    `verify_valid_live_stream_names` *returns* its `ValueError` instead of raising it
    ///    (`frigate/config/config.py:265`) - so this check is the only thing standing between a
    ///    config typo and a permanent spinner.
    /// 2. A candidate named after the camera wins. That is Frigate's own default mapping
    ///    (`config.py:990` writes `{name: name}`) and the near-universal convention for a
    ///    camera's main stream.
    /// 3. Otherwise the **label** decides, because the label is the user's own description of
    ///    what each stream is for - the closest thing to their intent we have once order is gone.
    ///    A label reading as a main/high stream beats one reading as a sub/low stream.
    /// 4. Otherwise the alphabetically first candidate, purely so the answer is stable.
    ///
    /// Step 3 is not theoretical: on a real 9-camera server *every* camera declared
    /// `Main Stream=camN, Sub Stream=camN_sub`, so this path runs for all of them. Sorting stream
    /// names would happen to get those right only because `cam2` is a prefix of `cam2_sub`; rename
    /// them `hi`/`lo` and it silently opens the low-res stream instead.
    ///
    /// It is still a heuristic. The real fix is letting the user choose (P8 stream picker), which
    /// is why `live.streams` keeps every label rather than collapsing to the winner.
    private static func restreamedStreamName(camera: String, config: FrigateConfig) -> String? {
        let restreams = config.go2rtc.streamNames
        let declared = config.cameras[camera]?.live.streams ?? []

        guard !declared.isEmpty else {
            // No mapping at all - an older or partial payload, since a real server fills this with
            // `{name: name}`. Apply that same default before giving up.
            return restreams.contains(camera) ? camera : nil
        }

        let candidates = declared.filter { restreams.contains($0.name) }
        if candidates.contains(where: { $0.name == camera }) {
            return camera
        }
        if let preferred = candidates.filter({ isMainStreamLabel($0.label) }).map(\.name).sorted().first {
            return preferred
        }
        // Note this deliberately does *not* fall back to the camera name when the camera declared
        // streams and none of them exist. That is a config error, and quietly playing a stream the
        // user did not ask for would hide it - the PWA drops such a camera to jsmpeg for the same
        // reason. MJPEG (P4.2) is our equivalent.
        return candidates.map(\.name).sorted().first
    }

    /// Does this label read as a camera's primary stream rather than a downscaled one?
    ///
    /// Keyword matching, which is exactly as crude as it sounds - but it is matching against text a
    /// human wrote to describe their own streams, using the vocabulary Frigate's own documentation
    /// uses (`Main Stream` / `Sub Stream`). That beats inferring quality from a stream *name* like
    /// `cam2_sub`, which is an identifier and carries no promise of meaning anything at all.
    private static func isMainStreamLabel(_ label: String) -> Bool {
        let normalized = label.lowercased()
        let subStreamWords = ["sub", "low", "secondary", "sd", "small", "detect"]
        guard !subStreamWords.contains(where: normalized.contains) else { return false }
        let mainStreamWords = ["main", "high", "primary", "hd", "4k", "full", "hi"]
        return mainStreamWords.contains(where: normalized.contains)
    }
}
