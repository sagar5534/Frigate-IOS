import Foundation

/// Minimal decodable subset of Frigate's `/api/config` needed for P1. The value type of
/// `cameras` expands in P2; unknown keys in the payload are ignored.
nonisolated struct FrigateConfig: Decodable, Equatable, Sendable {
    let auth: AuthInfo
    let cameras: [String: CameraConfig]

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

    struct CameraConfig: Decodable, Equatable, Sendable {}
}
