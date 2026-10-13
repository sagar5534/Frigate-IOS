import SwiftUI

/// A live video source for one camera.
///
/// The seam the whole live-view ladder hangs off: WebRTC (P4) ships first, MSE (P4.1) and MJPEG
/// (P4.2) drop in behind the same interface without touching call sites. Each player owns its own
/// render surface because the surfaces are genuinely different (`RTCMTLVideoView` vs
/// `AVSampleBufferDisplayLayer` vs an `Image`), which keeps Metal-layer details out of SwiftUI code.
@MainActor
protocol LivePlayer: AnyObject {
    var state: LivePlayerState { get }
    /// Which rung of the ladder this actually is, so the UI can name the tier it fell back to.
    var transport: LiveTransport { get }
    /// The incoming video's pixel dimensions once known, so the UI can shape its container to the
    /// stream rather than assuming 16:9. A property of the media, not of any rendering technology,
    /// so every tier can answer it.
    var videoSize: CGSize? { get }
    /// Whether this transport can receive camera audio. MJPEG has no audio channel, and the
    /// current MSE demuxer is deliberately video-only, so callers must not present a working mute
    /// control merely because a player exists.
    var supportsAudio: Bool { get }
    /// The requested playback state. Players default to muted so opening a camera never starts
    /// sound unexpectedly.
    var isMuted: Bool { get }
    /// Called whenever `videoSize` changes, including a mid-stream resolution switch. A push
    /// channel rather than something to poll, for the same reason as `onStateChange`: players are
    /// not `@Observable`, so nothing downstream would ever notice a change on its own.
    /// Called on every state change. Players are not `@Observable` (SwiftUI can't observe through
    /// an existential), so the owning model republishes state through this rather than watching it.
    var onStateChange: (@MainActor (LivePlayerState) -> Void)? { get set }
    var onVideoSizeChange: (@MainActor (CGSize) -> Void)? { get set }
    /// Idempotent: calling twice must not open a second connection.
    func start()
    /// Full teardown. Safe to call twice, and safe to call before `start()`.
    func stop()
    /// Applies immediately when an audio track exists and is remembered for tracks that arrive
    /// later in the connection handshake.
    func setMuted(_ muted: Bool)
    var view: AnyView { get }
}

nonisolated enum LivePlayerState: Equatable, Sendable {
    case idle
    case connecting
    /// **Pixels are on screen.** Not merely "the transport connected" - a peer connection can reach
    /// `connected` and deliver nothing, which looks exactly like still connecting. Callers rely on
    /// this to decide when the snapshot underneath can stop refreshing, so it has to mean video.
    case playing
    /// Connected but no frames arriving. Recoverable; distinct from `.failed`.
    case stalled
    case failed(LivePlayerError)
}

nonisolated enum LivePlayerError: Equatable, Sendable {
    /// Couldn't reach or negotiate with the server - an HTTP-shaped failure.
    case signalingFailed
    /// Negotiated, but no candidate pair ever connected. Almost always port 8555 being unreachable
    /// from where the phone is. Its own case because it is the one failure with a specific,
    /// explainable cause - and what escalation to the MSE tier keys off.
    case iceFailed
    /// Connected, and then no video arrived. Distinct from `.iceFailed` because the advice is the
    /// opposite: the network is demonstrably fine and the camera or its stream is the problem.
    /// Telling someone to open port 8555 when the connection already succeeded sends them to
    /// reconfigure a router for nothing.
    case noVideo
    /// Media arrived and this device could not play it - an unsupported codec, or a malformed
    /// stream. Structural for the tier, like `.iceFailed`: the same bytes will fail the same way
    /// on retry, so the useful response is a different tier, not another attempt.
    case decodeFailed
    case connectionLost
    /// No tier in this build can play this camera.
    case notAvailable
}

/// Builds the player for one rung of the ladder, or `nil` when this build has no implementation
/// for that tier - which is not an error: the caller tries the next rung, and a camera with no
/// buildable rung at all keeps its P2 snapshot with live reported unavailable.
///
/// `LiveCameraModel` owns the walk down the ladder (both the initial pick and escalation when a
/// tier fails); this type only answers "can this build play that transport?". Adding a tier is one
/// case here plus its `LivePlayer` conformer.
nonisolated struct LivePlayerFactory {
    /// Replaces the built-in tier construction. The seam exists so `LiveCameraModel`'s reconnect
    /// and escalation policies can be driven against scripted players - otherwise the only way to
    /// test a backoff chain would be to break a real camera connection on a real server, repeatedly.
    typealias Build = @MainActor @Sendable (LiveTransport, FrigateClient) -> (any LivePlayer)?

    private let override: Build?

    init(override: Build? = nil) {
        self.override = override
    }

    @MainActor
    func makePlayer(for transport: LiveTransport, client: FrigateClient) -> (any LivePlayer)? {
        (override ?? Self.buildImplementedTier)(transport, client)
    }

    @MainActor
    private static func buildImplementedTier(_ transport: LiveTransport, _ client: FrigateClient) -> (any LivePlayer)? {
        switch transport {
        case .webrtc(let streamName):
            return WebRTCLivePlayer(streamName: streamName, client: client)
        case .mse(let streamName):
            return MSELivePlayer(streamName: streamName, client: client)
        case .mjpeg(let camera, let height, let fps):
            return MJPEGLivePlayer(camera: camera, height: height, fps: fps, client: client)
        }
    }
}
