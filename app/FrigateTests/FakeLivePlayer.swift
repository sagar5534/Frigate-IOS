import SwiftUI
// @preconcurrency: the app module compiles with Approachable Concurrency, which infers @Sendable
// on the protocol's @MainActor closure properties; the test target does not, so a plain import
// warns about the sendability mismatch on this conformance.
@preconcurrency @testable import Frigate

/// A `LivePlayer` whose transitions the test drives directly, so `LiveCameraModel`'s policy can be
/// exercised without a server, a peer connection, or a stopwatch.
@MainActor
final class FakeLivePlayer: LivePlayer {
    let transport: LiveTransport
    let supportsAudio: Bool
    private(set) var isMuted = true
    var onStateChange: (@MainActor (LivePlayerState) -> Void)?
    var onVideoSizeChange: (@MainActor (CGSize) -> Void)?

    var videoSize: CGSize? {
        didSet {
            guard let videoSize, videoSize != oldValue else { return }
            onVideoSizeChange?(videoSize)
        }
    }

    private(set) var state: LivePlayerState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        transport: LiveTransport = .webrtc(streamName: "cam1"),
        supportsAudio: Bool = true
    ) {
        self.transport = transport
        self.supportsAudio = supportsAudio
    }

    var view: AnyView { AnyView(EmptyView()) }

    func start() {
        startCount += 1
        state = .connecting
    }

    func stop() {
        stopCount += 1
        state = .idle
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    /// Push a transition as the real transport would have.
    func simulate(_ newState: LivePlayerState) {
        state = newState
    }
}
