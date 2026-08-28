import Foundation

/// Decodable subset of Frigate's `/api/config` needed through P4. `cameras` is a small dictionary
/// keyed by camera name (the response also repeats the name inside each value; we ignore that and
/// use the key); everything else in the huge real payload (detect/ffmpeg/motion/etc.) is unknown
/// keys, ignored by `Decodable`.
///
/// Every field added after P1 is decoded leniently, so a partial payload - or a fixture written
/// before the field existed - still decodes.
nonisolated struct FrigateConfig: Decodable, Equatable, Sendable {
    let auth: AuthInfo
    let cameras: [String: CameraConfig]
    /// The restream table. Present on every real server, absent in older fixtures.
    let go2rtc: Go2RTCInfo

    /// Camera names with `enabled: true`, sorted for stable display order.
    var enabledCameraNames: [String] {
        cameras.filter(\.value.enabled).keys.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case auth
        case cameras
        case go2rtc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        auth = try container.decode(AuthInfo.self, forKey: .auth)
        cameras = try container.decode([String: CameraConfig].self, forKey: .cameras)
        go2rtc = try container.decodeIfPresent(Go2RTCInfo.self, forKey: .go2rtc) ?? Go2RTCInfo()
    }

    struct AuthInfo: Decodable, Equatable, Sendable {
        let enabled: Bool
        let cookieName: String
        let sessionLength: Int
        let refreshTime: Int

        enum CodingKeys: String, CodingKey {
            case enabled
            case cookieName = "cookie_name"
            case sessionLength = "session_length"
            case refreshTime = "refresh_time"
        }
    }

    /// go2rtc's restream table. **Only the keys matter to us**: a stream's value is a URL string in
    /// some configs and an array of strings in others (`front: [rtsp://…, ffmpeg:front#audio=aac]`),
    /// and neither shape tells the app anything. Reading the key set out of a nested keyed
    /// container sidesteps modelling go2rtc's source syntax entirely.
    struct Go2RTCInfo: Decodable, Equatable, Sendable {
        let streamNames: Set<String>

        init(streamNames: Set<String> = []) {
            self.streamNames = streamNames
        }

        private enum CodingKeys: String, CodingKey {
            case streams
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A bare `go2rtc:` block with nothing under it decodes as null, not as an empty object.
            guard let streams = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .streams) else {
                streamNames = []
                return
            }
            streamNames = Set(streams.allKeys.map(\.stringValue))
        }
    }

    /// A camera can exist in config but be turned off (e.g. seasonal cameras); `enabled` defaults
    /// to `true` so fixtures/tests that omit it (matching older payloads) still decode.
    struct CameraConfig: Decodable, Equatable, Sendable {
        let enabled: Bool
        let live: LiveInfo

        init(enabled: Bool = true, live: LiveInfo = LiveInfo()) {
            self.enabled = enabled
            self.live = live
        }

        private enum CodingKeys: String, CodingKey {
            case enabled
            case live
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            live = try container.decodeIfPresent(LiveInfo.self, forKey: .live) ?? LiveInfo()
        }
    }

    /// A camera's `live -> streams` mapping: friendly label -> go2rtc stream name.
    ///
    /// **Sorted by label, and it has to be.** The PWA plays `Object.values(live.streams)[0]` -
    /// the user's declaration order, which JavaScript preserves. Swift cannot: `JSONDecoder`'s
    /// `allKeys` comes back in **hash order**, which is neither document order nor sorted, and
    /// Swift seeds its hasher per process - so reading keys in their natural order would pick a
    /// different stream on every app launch. Sorting is the cheapest thing that is at least
    /// deterministic; `LiveStreamSource` layers a meaningful preference on top of it. See
    /// `docs/LEARNINGS.md`.
    ///
    /// The array keeps every label so a stream picker (P8 quality switching) can present them all,
    /// which is the actual fix for guessing a default.
    ///
    /// The server fills this with `{camera_name: camera_name}` when the user leaves it unset
    /// (`frigate/config/config.py:990`), so a real response always has at least one entry and the
    /// choice only matters for the minority of cameras with several named streams.
    struct LiveInfo: Decodable, Equatable, Sendable {
        let streams: [Stream]

        init(streams: [Stream] = []) {
            self.streams = streams
        }

        struct Stream: Equatable, Sendable {
            let label: String
            let name: String

            init(label: String, name: String) {
                self.label = label
                self.name = name
            }
        }

        private enum CodingKeys: String, CodingKey {
            case streams
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let streams = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .streams) else {
                self.streams = []
                return
            }
            self.streams = try streams.allKeys
                .map { key in
                    Stream(label: key.stringValue, name: try streams.decode(String.self, forKey: key))
                }
                .sorted { $0.label < $1.label }
        }
    }
}
