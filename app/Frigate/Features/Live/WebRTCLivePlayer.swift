import SwiftUI
import WebRTC

/// The WebRTC rung of the live-view ladder (P4): go2rtc signaling over an authenticated WebSocket,
/// media over a peer connection, rendered by `RTCMTLVideoView`.
///
/// Sub-second latency, hardware decode, and audio available later - at the cost of a media path
/// that does not use the HTTPS origin everything else in this app rides. When that path is blocked
/// this player fails with `.iceFailed`, and until P4.1/P4.2 land there is no lower rung to fall to,
/// so saying *why* is the whole recovery story. See `docs/DECISIONS.md` ADR-012.
@MainActor
final class WebRTCLivePlayer: LivePlayer {
    let transport: LiveTransport
    var onStateChange: (@MainActor (LivePlayerState) -> Void)?

    private(set) var state: LivePlayerState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    private let streamName: String
    private let client: FrigateClient
    private let renderer: RTCMTLVideoView

    private var peerConnection: RTCPeerConnection?
    private var observer: PeerConnectionObserver?
    private var socket: LiveSocket?
    private var tasks: [Task<Void, Never>] = []
    private var isStarted = false
    /// Whether media ever flowed. Decides whether a `.failed` transition means "could never reach
    /// the camera" or "reached it and lost it" - different causes, different things to tell the user.
    private var hasPlayed = false

    init(streamName: String, client: FrigateClient) {
        self.transport = .webrtc(streamName: streamName)
        self.streamName = streamName
        self.client = client
        self.renderer = RTCMTLVideoView()
        renderer.videoContentMode = .scaleAspectFill
    }

    var view: AnyView {
        AnyView(LiveVideoView(renderer: renderer))
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        state = .connecting
        tasks.append(Task { await self.connect() })
    }

    func stop() {
        isStarted = false
        hasPlayed = false

        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()

        // Finish the observer's stream *before* closing the peer connection: closing fires a final
        // `.closed` transition that is our own doing and that nothing should react to.
        observer?.finish()
        observer = nil

        peerConnection?.close()
        peerConnection = nil

        if let socket {
            self.socket = nil
            Task { await socket.close() }
        }

        state = .idle
    }

    /// Every transition after `start()` goes through here. `stop()` cancels the connect task, but
    /// cancellation is cooperative and the task can still be parked on an `await` - so a late
    /// `.failed` can land on a player nobody is watching any more, showing an error for a stream
    /// that was deliberately torn down. Dropping transitions on a stopped player is the fix.
    private func transition(to newState: LivePlayerState) {
        guard isStarted else { return }
        state = newState
    }

    // MARK: Connection

    private func connect() async {
        do {
            let socket = try await client.liveSocket(for: .webrtcWebSocket(src: streamName))
            await socket.start()
            self.socket = socket
            let signaling = WebRTCSignaling(channel: socket)

            let observer = PeerConnectionObserver()
            self.observer = observer

            guard let peerConnection = Self.factory.peerConnection(
                with: Self.configuration,
                constraints: Self.mediaConstraints,
                delegate: observer
            ) else {
                transition(to: .failed(.signalingFailed))
                return
            }
            self.peerConnection = peerConnection

            // Video only. Audio is out of P4's scope, and *asking* for it invites a class of
            // negotiation failure against cameras with no audio or an odd codec - for a track we
            // would discard. Adding it later is this one transceiver.
            let transceiverInit = RTCRtpTransceiverInit()
            transceiverInit.direction = .recvOnly
            let transceiver = peerConnection.addTransceiver(of: .video, init: transceiverInit)

            // Under Unified Plan a `recvonly` transceiver's receiver already has its track, so the
            // renderer can be attached now rather than waiting on a delegate callback. Same thing
            // the PWA does with `pc.addTransceiver(kind, {direction:'recvonly'}).receiver.track`.
            (transceiver?.receiver.track as? RTCVideoTrack)?.add(renderer)

            tasks.append(Task { await self.forwardLocalEvents(from: observer, to: signaling) })
            tasks.append(Task { await self.applyRemoteSignaling(from: signaling, to: peerConnection) })

            let offer = try await peerConnection.offer(for: Self.mediaConstraints)
            try await peerConnection.setLocalDescription(offer)
            try await signaling.send(.offer(sdp: offer.sdp))
        } catch {
            transition(to: .failed(.signalingFailed))
        }
    }

    /// Our candidates, trickled up to go2rtc, plus the connection-state transitions.
    private func forwardLocalEvents(from observer: PeerConnectionObserver, to signaling: WebRTCSignaling) async {
        for await event in observer.events {
            switch event {
            case .localCandidate(let sdp):
                // A candidate we can't deliver is not fatal on its own - the peer connection may
                // still succeed on candidates already exchanged, and if it doesn't, the connection
                // state will say so with a better error than this would.
                try? await signaling.send(.candidate(sdp))
            case .connectionState(let connectionState):
                apply(connectionState)
            }
        }
    }

    /// go2rtc's answer and candidates, applied to the peer connection. `WebRTCSignaling` has already
    /// guaranteed the answer arrives first, so each message here can be applied as it comes.
    private func applyRemoteSignaling(from signaling: WebRTCSignaling, to peerConnection: RTCPeerConnection) async {
        for await message in await signaling.events() {
            do {
                switch message {
                case .answer(let sdp):
                    try await peerConnection.setRemoteDescription(
                        RTCSessionDescription(type: .answer, sdp: sdp)
                    )
                case .candidate(let candidate):
                    // go2rtc sends candidates with no sdpMid or sdpMLineIndex. The PWA supplies
                    // `sdpMid: "0"`; with `maxBundle` there is exactly one bundled m-line, so index
                    // 0 is not a guess.
                    try await peerConnection.add(
                        RTCIceCandidate(sdp: candidate, sdpMLineIndex: 0, sdpMid: "0")
                    )
                case .offer:
                    continue
                }
            } catch {
                transition(to: .failed(.signalingFailed))
                return
            }
        }

        // The signaling channel ended. Once media is flowing that is fine - go2rtc has no reason to
        // keep talking, and the peer connection carries on without it. Before that, it means the
        // handshake never completed.
        if !hasPlayed, case .connecting = state {
            transition(to: .failed(.signalingFailed))
        }
    }

    private func apply(_ connectionState: RTCPeerConnectionState) {
        switch connectionState {
        case .connected:
            hasPlayed = true
            transition(to: .playing)
        case .disconnected:
            // Recoverable by design: libwebrtc keeps trying, and often recovers without help.
            transition(to: .stalled)
        case .failed:
            // Negotiated, but no candidate pair ever connected. If media never flowed, that is
            // almost always port 8555 being unreachable from wherever the phone is - the one
            // failure with a cause worth naming out loud (C5 writes that copy).
            transition(to: .failed(hasPlayed ? .connectionLost : .iceFailed))
        case .new, .connecting, .closed:
            break
        @unknown default:
            break
        }
    }

    // MARK: libwebrtc setup

    /// One factory for the process - it owns codec registration and worker threads, and building
    /// one per player would be pure waste. `RTCInitializeSSL` must run before any of it.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private static var configuration: RTCConfiguration {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        // Matches the PWA. Only reached when go2rtc advertises no usable local candidate; a LAN
        // setup never needs it. It is also the only thing in this app that talks to a third party,
        // which is worth remembering if that ever becomes a constraint.
        configuration.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        return configuration
    }

    private static var mediaConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }
}
