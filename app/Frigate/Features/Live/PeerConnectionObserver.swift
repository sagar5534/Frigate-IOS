import Foundation
import WebRTC

/// The subset of libwebrtc's delegate traffic `WebRTCLivePlayer` acts on.
nonisolated enum PeerConnectionEvent: Sendable {
    /// A local ICE candidate to trickle back to go2rtc.
    case localCandidate(sdp: String)
    /// Overall connection state - the one that separates "never connected" from "connected then
    /// dropped", which is the difference between blaming port 8555 and blaming the network.
    case connectionState(RTCPeerConnectionState)
}

/// Bridges `RTCPeerConnectionDelegate` onto an ordered `AsyncStream` the main-actor player consumes.
///
/// It has to be `nonisolated`: the project defaults every type to `@MainActor`
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION`), and a main-actor object cannot satisfy a protocol libwebrtc
/// calls from its own signaling thread. Same shape as `InsecureTrustDelegate`; see `LEARNINGS.md`.
///
/// An `AsyncStream` rather than a `Task { @MainActor in … }` per callback, because **ordering is
/// load-bearing**. Independent tasks have no ordering guarantee between them, so candidate
/// generation could be delivered out of order relative to the connection-state transitions - a bug
/// that would appear only under load and be genuinely awful to chase. A stream delivers in order.
nonisolated final class PeerConnectionObserver: NSObject, RTCPeerConnectionDelegate {
    let events: AsyncStream<PeerConnectionEvent>
    private let continuation: AsyncStream<PeerConnectionEvent>.Continuation

    /// The remote video track, handed over the moment libwebrtc creates its receiver.
    ///
    /// Not routed through `events`: `RTCVideoTrack` is a non-`Sendable` reference type, and this is
    /// a one-shot handoff where ordering against the state transitions doesn't matter.
    private let onVideoTrack: @Sendable (RTCVideoTrack) -> Void

    init(onVideoTrack: @escaping @Sendable (RTCVideoTrack) -> Void) {
        let (events, continuation) = AsyncStream<PeerConnectionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.onVideoTrack = onVideoTrack
        super.init()
    }

    /// The canonical place to pick up a remote track. Attaching renderers to the track reachable
    /// from `addTransceiver(...)?.receiver.track` looks equivalent and is not: measured against a
    /// real camera, that track decoded 73 frames without ever calling a renderer attached to it.
    /// This callback hands over the track libwebrtc actually feeds.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        onVideoTrack(track)
    }

    /// Ends the event stream so the player's consuming loop exits. Called during teardown, before
    /// the peer connection is closed - the `.closed` transition that follows is our own doing and
    /// nothing needs to react to it.
    func finish() {
        continuation.finish()
    }

    // MARK: Acted on

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        continuation.yield(.localCandidate(sdp: candidate.sdp))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        continuation.yield(.connectionState(newState))
    }

    // MARK: Required by the protocol, deliberately unused
    //
    // `RTCPeerConnectionDelegate` requires all of these. We watch `RTCPeerConnectionState` instead
    // of the legacy ICE state because it is the aggregate one, and the stream-based callbacks never
    // fire under Unified Plan - a `recvonly` transceiver hands us its track directly.

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
