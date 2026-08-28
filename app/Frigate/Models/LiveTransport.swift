import Foundation

/// One way of watching a camera live.
///
/// All three tiers are enumerated from the start even though only `.webrtc` has an implementation
/// today (P4). `.mse` (P4.1) and `.mjpeg` (P4.2) each land later as one more `LivePlayer` conformer
/// plus one case in `LivePlayerFactory`, with no call-site changes. See `docs/DECISIONS.md`
/// ADR-012 for why Frigate offers no live HLS and why the ladder is ordered this way.
nonisolated enum LiveTransport: Equatable, Sendable {
    /// go2rtc WebRTC. Sub-second, but its media rides port 8555 rather than the HTTPS origin.
    /// `streamName` is the **go2rtc stream name**, which is not always the camera name.
    case webrtc(streamName: String)
    /// go2rtc MSE (fMP4 over WebSocket) - real video over the same authenticated origin. **P4.1.**
    case mse(streamName: String)
    /// Frigate's own MJPEG feed off the low-res detect stream. Works anywhere. **P4.2.**
    case mjpeg(camera: String)
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
        guard let streamName = restreamedStreamName(camera: camera, config: config) else {
            return [.mjpeg(camera: camera)]
        }
        return [
            .webrtc(streamName: streamName),
            .mse(streamName: streamName),
            .mjpeg(camera: camera),
        ]
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
    ///    camera's main stream, so it matches the PWA's pick for the overwhelming majority of
    ///    configs, single-stream ones included.
    /// 3. Otherwise the alphabetically first candidate, purely so the answer is stable.
    ///
    /// Step 3 is a guess, and for a multi-stream camera we may open a different stream than the
    /// PWA would. The real fix is letting the user choose (P8 stream picker) - `live.streams`
    /// keeps every label for exactly that.
    private static func restreamedStreamName(camera: String, config: FrigateConfig) -> String? {
        let restreams = config.go2rtc.streamNames
        let configured = config.cameras[camera]?.live.streams.map(\.name) ?? []

        guard !configured.isEmpty else {
            // No mapping at all - an older or partial payload, since a real server fills this with
            // `{name: name}`. Apply that same default before giving up.
            return restreams.contains(camera) ? camera : nil
        }

        let candidates = configured.filter(restreams.contains)
        if candidates.contains(camera) {
            return camera
        }
        // Note this deliberately does *not* fall back to the camera name when the camera declared
        // streams and none of them exist. That is a config error, and quietly playing a stream the
        // user did not ask for would hide it - the PWA drops such a camera to jsmpeg for the same
        // reason. MJPEG (P4.2) is our equivalent.
        return candidates.sorted().first
    }
}
