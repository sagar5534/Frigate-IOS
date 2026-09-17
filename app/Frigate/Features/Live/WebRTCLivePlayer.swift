import OSLog
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
    var onVideoSizeChange: (@MainActor (CGSize) -> Void)?

    private(set) var videoSize: CGSize? {
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

    private let streamName: String
    private let client: FrigateClient
    private let renderer: RTCMTLVideoView

    private var peerConnection: RTCPeerConnection?
    private var observer: PeerConnectionObserver?
    private var frameObserver: VideoFrameObserver?
    /// **Must be retained.** `RTCVideoTrack` owns the renderer adapters registered through
    /// `add(_:)`, and unregisters them when it deallocates. Attaching to a track you don't hold
    /// compiles, runs, logs nothing, and silently delivers no frames - see `LEARNINGS.md`.
    private var videoTrack: RTCVideoTrack?
    private var socket: LiveSocket?
    private var tasks: [Task<Void, Never>] = []
    private var isStarted = false
    /// Identifies one connection attempt, so a superseded `connect()` can tell it is stale.
    private var connectionEpoch = 0
    /// Whether media ever flowed. Decides whether a `.failed` transition means "could never reach
    /// the camera" or "reached it and lost it" - different causes, different things to tell the user.
    private var hasPlayed = false
    /// `.playing` is promised to mean *pixels on screen*, not merely "ICE succeeded". A peer
    /// connection can reach `connected` and deliver nothing - a black view that looks identical to
    /// still-connecting - so both of these must be true before the state advances.
    private var isConnected = false
    private var hasVideoFrames = false
    private var localCandidateCount = 0
    private var remoteCandidateCount = 0
    private let frameWatchdog = FrameLivenessWatchdog()
    private var statsProbe: Task<Void, Never>?

    init(streamName: String, client: FrigateClient) {
        self.transport = .webrtc(streamName: streamName)
        self.streamName = streamName
        self.client = client
        self.renderer = RTCMTLVideoView()
        renderer.videoContentMode = .scaleAspectFill

        self.frameObserver = VideoFrameObserver(
            onFirstFrame: { [weak self] in
                Task { @MainActor [weak self] in self?.markVideoFrameArrived() }
            },
            onSize: { [weak self] size in
                Task { @MainActor [weak self] in self?.videoSize = size }
            }
        )
    }

    var view: AnyView {
        AnyView(LiveVideoView(renderer: renderer))
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        connectionEpoch += 1
        let epoch = connectionEpoch
        state = .connecting
        tasks.append(Task { await self.connect(epoch: epoch) })
    }

    func stop() {
        isStarted = false
        hasPlayed = false
        isConnected = false
        hasVideoFrames = false
        localCandidateCount = 0
        remoteCandidateCount = 0
        videoSize = nil
        frameObserver?.reset()
        frameWatchdog.cancel()
        statsProbe?.cancel()
        statsProbe = nil

        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()

        // Finish the observer's stream *before* closing the peer connection: closing fires a final
        // `.closed` transition that is our own doing and that nothing should react to.
        observer?.finish()
        observer = nil

        if let videoTrack {
            videoTrack.remove(renderer)
            if let frameObserver {
                videoTrack.remove(frameObserver)
            }
            self.videoTrack = nil
        }

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

    /// Abandons a connection attempt that `stop()` overtook, tearing down whatever it had already
    /// built.
    ///
    /// None of `connect()`'s awaits are cancellable suspension points - they are actor hops and
    /// continuation-wrapped ObjC callbacks - so a cancelled task runs to completion regardless.
    /// Without this check a `stop()` mid-connect leaves an open socket and an ICE-gathering peer
    /// connection assigned to a player the model has already released, with no handle left to close
    /// them: a silent, permanent leak that repeats every time it happens.
    private func abandonIfStopped(
        epoch: Int,
        socket: LiveSocket?,
        peerConnection: RTCPeerConnection?
    ) -> Bool {
        // Compares a generation rather than just `isStarted`, so a `stop()` immediately followed by
        // `start()` still abandons the older attempt. `LivePlayer` documents `start()` as idempotent
        // and the player as reusable across reconnects, and an `isStarted`-only check would let a
        // stale in-flight `connect()` overwrite the new attempt's socket and peer connection.
        guard !isStarted || epoch != connectionEpoch else { return false }
        LiveLog.logger.info("connect abandoned after teardown src=\(self.streamName, privacy: .public)")
        peerConnection?.close()
        if let socket {
            Task { await socket.close() }
        }
        return true
    }

    private func connect(epoch: Int) async {
        do {
            let request = try await client.webSocketRequest(for: .webrtcWebSocket(src: streamName))
            guard !abandonIfStopped(epoch: epoch, socket: nil, peerConnection: nil) else { return }
            LiveLog.logger.info("opening signaling socket src=\(self.streamName, privacy: .public) url=\(request.url?.absoluteString ?? "nil", privacy: .public) hasCookie=\(request.value(forHTTPHeaderField: "Cookie") != nil, privacy: .public)")
            let socket = try await client.liveSocket(for: .webrtcWebSocket(src: streamName))
            guard !abandonIfStopped(epoch: epoch, socket: socket, peerConnection: nil) else { return }
            await socket.start()
            guard !abandonIfStopped(epoch: epoch, socket: socket, peerConnection: nil) else { return }
            self.socket = socket
            let signaling = WebRTCSignaling(channel: socket)

            let observer = PeerConnectionObserver { [weak self] track in
                Task { @MainActor [weak self] in self?.attachRenderers(to: track) }
            }
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
            LiveLog.logger.info("transceiver=\(transceiver != nil, privacy: .public) track=\(String(describing: transceiver?.receiver.track?.kind), privacy: .public)")

            // Under Unified Plan a `recvonly` transceiver's receiver already has its track, so the
            // renderer can be attached now rather than waiting on a delegate callback. Same thing
            // the PWA does with `pc.addTransceiver(kind, {direction:'recvonly'}).receiver.track`.
            // Renderers are deliberately *not* attached from `transceiver.receiver.track` here -
            // that track decoded 73 frames without ever calling a renderer added to it. They attach
            // in `attachRenderers(to:)` when libwebrtc reports the receiver. See `LEARNINGS.md`.

            tasks.append(Task { await self.applyRemoteSignaling(from: signaling, to: peerConnection) })

            let offer = try await peerConnection.offer(for: Self.mediaConstraints)
            guard !abandonIfStopped(epoch: epoch, socket: socket, peerConnection: peerConnection) else { return }
            try await peerConnection.setLocalDescription(offer)
            guard !abandonIfStopped(epoch: epoch, socket: socket, peerConnection: peerConnection) else { return }
            try await signaling.send(.offer(sdp: offer.sdp))
            guard !abandonIfStopped(epoch: epoch, socket: socket, peerConnection: peerConnection) else { return }
            LiveLog.logger.info("offer sent src=\(self.streamName, privacy: .public)")

            // Only now start trickling our candidates. go2rtc creates its peer connection when it
            // handles `webrtc/offer`, so a candidate that overtakes the offer has nothing to attach
            // to and is dropped - and on a LAN the host candidate it drops may be the only one that
            // would have worked. libwebrtc can fire `OnIceCandidate` before `setLocalDescription`
            // returns, so ordering here is not theoretical. The PWA is safe from this by accident:
            // its offer chain is microtasks and candidate events are macrotasks.
            tasks.append(Task { await self.forwardLocalEvents(from: observer, to: signaling) })
        } catch {
            LiveLog.logger.error("signaling setup failed src=\(self.streamName, privacy: .public) error=\(String(describing: error), privacy: .public)")
            transition(to: .failed(.signalingFailed))
        }
    }

    /// Our candidates, trickled up to go2rtc, plus the connection-state transitions.
    private func forwardLocalEvents(from observer: PeerConnectionObserver, to signaling: WebRTCSignaling) async {
        for await event in observer.events {
            switch event {
            case .localCandidate(let sdp):
                localCandidateCount += 1
                LiveLog.logger.info("local candidate \(self.localCandidateCount, privacy: .public): \(sdp, privacy: .public)")
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
                    let codecs = sdp
                        .split(separator: "\r\n")
                        .filter { $0.hasPrefix("a=rtpmap:") }
                        .joined(separator: " ")
                    LiveLog.logger.info("answer received src=\(self.streamName, privacy: .public) codecs=\(codecs, privacy: .public)")
                    try await peerConnection.setRemoteDescription(
                        RTCSessionDescription(type: .answer, sdp: sdp)
                    )
                case .candidate(let candidate):
                    remoteCandidateCount += 1
                    LiveLog.logger.info("remote candidate \(self.remoteCandidateCount, privacy: .public): \(candidate, privacy: .public)")
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
                LiveLog.logger.error("applying remote signaling failed error=\(String(describing: error), privacy: .public)")
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
        LiveLog.logger.info("connection state=\(connectionState.rawValue, privacy: .public) src=\(self.streamName, privacy: .public) local=\(self.localCandidateCount, privacy: .public) remote=\(self.remoteCandidateCount, privacy: .public) frames=\(self.hasVideoFrames, privacy: .public)")
        switch connectionState {
        case .connected:
            isConnected = true
            statsProbe?.cancel()
            statsProbe = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                await self?.logInboundStats()
            }
        case .disconnected:
            // If ICE recovers while the camera has stopped sending, a stale `true` would re-report
            // `.playing` over a frozen picture - so forget the frames we had seen.
            isConnected = false
            forgetVideoFrames()
        default:
            break
        }

        if let next = Self.nextState(
            for: connectionState,
            hasPlayed: hasPlayed,
            hasVideoFrames: hasVideoFrames
        ) {
            if next == .playing {
                hasPlayed = true
            }
            transition(to: next)
        }
    }

    /// The whole connection-state mapping as a pure function, so the decisions that produce this
    /// phase's user-facing error messages can be tested without a server or a peer connection.
    ///
    /// `nil` means "no state change" - `.new`, `.connecting` and `.closed` are all transitions we
    /// either already reported or caused ourselves.
    nonisolated static func nextState(
        for connectionState: RTCPeerConnectionState,
        hasPlayed: Bool,
        hasVideoFrames: Bool
    ) -> LivePlayerState? {
        switch connectionState {
        case .connected:
            // Connected-without-frames is `.stalled`, not `.connecting`. The two mean different
            // things to whoever is diagnosing it: still connecting could be a blocked media path,
            // whereas connected-and-silent proves the path works and points at the camera.
            return hasVideoFrames ? .playing : .stalled
        case .disconnected:
            // Recoverable by design: libwebrtc keeps trying, and often recovers without help.
            return .stalled
        case .failed:
            // If media never flowed, no candidate pair ever connected - almost always port 8555
            // being unreachable from wherever the phone is. If it did, a working stream dropped.
            return .failed(hasPlayed ? .connectionLost : .iceFailed)
        case .new, .connecting, .closed:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Hooks the on-screen view and the frame observer up to the remote track.
    private func attachRenderers(to track: RTCVideoTrack) {
        LiveLog.logger.info("remote video track attached src=\(self.streamName, privacy: .public)")
        videoTrack = track
        track.add(renderer)
        // A second renderer on the same track, purely to observe. See `VideoFrameObserver` for why
        // the on-screen view can't be trusted to report this itself.
        if let frameObserver {
            track.add(frameObserver)
        }
    }

    /// Is media actually arriving, and is anything decoding it?
    ///
    /// Worth its keep: this line is what separated "the media path is blocked" from "the media path
    /// works and our renderer was never wired up" while chasing a silent black stream. On screen
    /// those are identical, and without numbers the natural conclusion is the wrong one.
    private func logInboundStats() async {
        guard let peerConnection else { return }
        let report = await peerConnection.statistics()
        for (_, stats) in report.statistics where stats.type == "inbound-rtp" {
            let bytes = stats.values["bytesReceived"].map(String.init(describing:)) ?? "?"
            let received = stats.values["framesReceived"].map(String.init(describing:)) ?? "?"
            let decoded = stats.values["framesDecoded"].map(String.init(describing:)) ?? "?"
            let width = stats.values["frameWidth"].map(String.init(describing:)) ?? "?"
            LiveLog.logger.info("inbound-rtp bytes=\(bytes, privacy: .public) received=\(received, privacy: .public) decoded=\(decoded, privacy: .public) width=\(width, privacy: .public)")
        }
    }

    /// Forgets that video was flowing, so the next decoded frame counts as a fresh arrival.
    ///
    /// **Both halves are required.** `hasVideoFrames` is only ever set from `markVideoFrameArrived`,
    /// which the observer calls only for the *first* frame after a reset. Clearing the player's flag
    /// without re-arming the observer therefore latches it false for the life of the player: a wifi
    /// blip would leave "Reconnecting" sitting over moving video until the stall deadline tore down
    /// a stream that was working perfectly. That is the third time in this phase a liveness signal
    /// that fires once has been mistaken for one that fires continuously.
    private func forgetVideoFrames() {
        hasVideoFrames = false
        frameObserver?.reset()
    }

    private func markVideoFrameArrived() {
        guard !hasVideoFrames else { return }
        LiveLog.logger.info("first video frame src=\(self.streamName, privacy: .public)")
        hasVideoFrames = true
        startFrameWatchdog()
        advanceIfShowingVideo()
    }

    /// Reports `.stalled` when frames stop arriving on a connection that is still nominally up.
    ///
    /// ICE consent keeps a peer connection `connected` long after RTP has stopped, so without this
    /// a camera that quietly stops sending leaves a frozen picture claiming `.playing` forever -
    /// the worst kind of failure, because it looks like success.
    private func startFrameWatchdog() {
        frameWatchdog.start(
            lastFrameAt: { [weak self] in self?.frameObserver?.lastFrameAt },
            onStall: { [weak self] in
                guard let self else { return }
                LiveLog.logger.info("frames stopped src=\(self.streamName, privacy: .public)")
                self.forgetVideoFrames()
                self.transition(to: .stalled)
            }
        )
    }

    /// Only claim `.playing` once the connection is up *and* a frame has actually arrived. Until
    /// both hold, the caller keeps showing the snapshot, which is the truthful picture.
    private func advanceIfShowingVideo() {
        guard isConnected, hasVideoFrames else { return }
        hasPlayed = true
        transition(to: .playing)
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
