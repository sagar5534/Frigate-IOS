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
    /// Couldn't reach or negotiate with go2rtc - an HTTP-shaped failure.
    case signalingFailed
    /// Negotiated, but no candidate pair ever connected. Almost always port 8555 being unreachable
    /// from where the phone is. Its own case because it is the one failure with a specific,
    /// explainable cause - and eventually what P4.2 keys its fallback off.
    case iceFailed
    /// Connected, and then no video arrived. Distinct from `.iceFailed` because the advice is the
    /// opposite: the network is demonstrably fine and the camera or its stream is the problem.
    /// Telling someone to open port 8555 when the connection already succeeded sends them to
    /// reconfigure a router for nothing.
    case noVideo
    case connectionLost
    /// No tier in this build can play this camera.
    case notAvailable
}

/// Builds the best rung of a ladder that has an implementation **in this build**, skipping the
/// rest. Returns `nil` when none do, which is not an error: the caller keeps showing the P2
/// snapshot and reports live as unavailable.
///
/// Adding a tier is one case here plus its `LivePlayer` conformer. Automatic *escalation* - falling
/// to the next rung when a connected tier dies - is deliberately deferred until a second rung
/// exists to escalate to (P4.2); the ladder being an ordered list is what keeps that additive.
nonisolated struct LivePlayerFactory {
    /// Replaces the built-in tier construction. The seam exists so `LiveCameraModel`'s reconnect
    /// policy can be driven against a scripted player - otherwise the only way to test a backoff
    /// chain would be to break a real camera connection on a real server, repeatedly.
    typealias Build = @MainActor @Sendable (LiveTransport, FrigateClient) -> (any LivePlayer)?

    private let override: Build?

    init(override: Build? = nil) {
        self.override = override
    }

    @MainActor
    func makePlayer(for ladder: [LiveTransport], client: FrigateClient) -> (any LivePlayer)? {
        let build = override ?? Self.buildImplementedTier
        for transport in ladder {
            if let player = build(transport, client) {
                return player
            }
        }
        return nil
    }

    /// One rung. `nil` means "this build has no implementation for that tier", not a failure.
    @MainActor
    private static func buildImplementedTier(_ transport: LiveTransport, _ client: FrigateClient) -> (any LivePlayer)? {
        switch transport {
        case .webrtc(let streamName):
            return WebRTCLivePlayer(streamName: streamName, client: client)
        case .mse:
            return nil  // P4.1: MSELivePlayer
        case .mjpeg:
            return nil  // P4.2: MJPEGLivePlayer
        }
    }
}
