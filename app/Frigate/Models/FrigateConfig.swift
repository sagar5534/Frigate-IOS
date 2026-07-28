import Foundation

/// Decodable subset of Frigate's `/api/config` needed through P2. `cameras` is a small dictionary
/// keyed by camera name (the response also repeats the name inside each value; we ignore that and
/// use the key); everything else in the huge real payload (detect/ffmpeg/motion/etc.) is unknown
/// keys, ignored by `Decodable`.
nonisolated struct FrigateConfig: Decodable, Equatable, Sendable {
    let auth: AuthInfo
    let cameras: [String: CameraConfig]

    /// Camera names with `enabled: true`, sorted for stable display order.
    var enabledCameraNames: [String] {
        cameras.filter(\.value.enabled).keys.sorted()
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

    /// A camera can exist in config but be turned off (e.g. seasonal cameras); `enabled` defaults
    /// to `true` so fixtures/tests that omit it (matching older payloads) still decode.
    struct CameraConfig: Decodable, Equatable, Sendable {
        let enabled: Bool

        init(enabled: Bool = true) {
            self.enabled = enabled
        }

        private enum CodingKeys: String, CodingKey {
            case enabled
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }
    }
}
