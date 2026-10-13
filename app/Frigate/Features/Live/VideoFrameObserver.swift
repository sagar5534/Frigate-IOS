import Foundation
import Synchronization
import WebRTC

/// Reports the moment real video frames start arriving.
///
/// This is an `RTCVideoRenderer` attached to the track alongside the on-screen view, rather than a
/// delegate of that view - deliberately. `RTCMTLVideoView.delegate` only fires as a side effect of
/// the view actually *rendering*, which needs the view in a window, with non-zero bounds, on a
/// device where Metal is available. Measured against a real camera: 62 frames received and 2 key
/// frames decoded, and the view's delegate never fired once. Hanging "is video flowing?" off a
/// rendering side effect answers a different question than the one being asked.
///
/// As a renderer we sit in the media pipeline itself, so we see frames whenever they are decoded,
/// whatever the view is doing.
///
/// `nonisolated` for the same reason as `PeerConnectionObserver`: libwebrtc calls this from its own
/// decoder thread and the project defaults types to `@MainActor`.
nonisolated final class VideoFrameObserver: NSObject, RTCVideoRenderer {
    private let onFirstFrame: @Sendable () -> Void
    private let onSize: @Sendable (CGSize) -> Void
    private let state = Mutex(State())

    private struct State {
        var reportedFirstFrame = false
        var lastFrameAt: ContinuousClock.Instant?
    }

    init(onFirstFrame: @escaping @Sendable () -> Void, onSize: @escaping @Sendable (CGSize) -> Void) {
        self.onFirstFrame = onFirstFrame
        self.onSize = onSize
        super.init()
    }

    /// When the most recent frame arrived, for a liveness check.
    ///
    /// Read on demand rather than pushed: frames arrive at the stream's frame rate, and hopping to
    /// the main actor tens of times a second to say "still fine" would cost far more than the
    /// watchdog it feeds. A lock-guarded timestamp the watchdog samples every few seconds is the
    /// whole mechanism.
    var lastFrameAt: ContinuousClock.Instant? {
        state.withLock(\.lastFrameAt)
    }

    /// Lets one observer be reused across reconnects.
    func reset() {
        state.withLock { $0 = State() }
    }

    /// Called when the stream's dimensions are known, and again if the camera switches resolution.
    func setSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        onSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        // Called for every frame at the stream's frame rate. Every one refreshes the liveness
        // timestamp; only the first is worth waking anyone up for.
        let isFirst = state.withLock { state -> Bool in
            state.lastFrameAt = .now
            guard !state.reportedFirstFrame else { return false }
            state.reportedFirstFrame = true
            return true
        }
        if isFirst {
            onFirstFrame()
        }
    }
}
