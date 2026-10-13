import AVFoundation
import CoreMedia
import Foundation
import OSLog
import SwiftUI

/// The MSE rung of the live-view ladder (P4.1): go2rtc's fMP4-over-WebSocket stream, demuxed by
/// `FMP4Demuxer` and decoded by VideoToolbox via `AVSampleBufferDisplayLayer`.
///
/// Everything rides the **same authenticated HTTPS origin** as the rest of the app - no port 8555,
/// no separate media path - which is exactly why this tier exists: it reaches users behind
/// Cloudflare Tunnel and every other setup WebRTC's media path cannot cross, at the cost of a
/// second or two more latency. See ADR-012.
@MainActor
final class MSELivePlayer: LivePlayer {
    /// How the player gets its socket. Injectable so the handshake and demux pipeline can be
    /// driven by a scripted `MediaChannel` in tests; the default is the client's cookie-authed
    /// WebSocket. The channel must arrive already receiving.
    typealias MakeChannel = @Sendable (FrigateClient, String) async throws -> any MediaChannel

    let transport: LiveTransport
    let supportsAudio = false
    private(set) var isMuted = true
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
    private let makeChannel: MakeChannel

    private let displayView = SampleBufferDisplayView()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var renderer: AVSampleBufferVideoRenderer { displayView.displayLayer.sampleBufferRenderer }
    private var rendererStatusObservation: NSKeyValueObservation?

    private var channel: (any MediaChannel)?
    private var tasks: [Task<Void, Never>] = []
    private var handshakeDeadline: Task<Void, Never>?
    private let sampleWatchdog = FrameLivenessWatchdog()
    private var isStarted = false
    private var connectionEpoch = 0
    private var hasPlayed = false
    private var hasVideo = false
    private var receivedMedia = false
    private var clockStarted = false
    private var lastSampleAt: ContinuousClock.Instant?
    private var demuxer = FMP4Demuxer()
    private var track: FMP4Demuxer.VideoTrack?

    /// Video codecs offered in the handshake; go2rtc muxes only what the client claims to play.
    /// H.264 high profile through 5.1 plus H.265 - both hardware-decoded on every device this app
    /// targets. Deliberately no audio, mirroring the WebRTC tier: requesting a track we would
    /// discard invites negotiation failures for nothing.
    private nonisolated static let offeredCodecs = "avc1.640029,avc1.64002A,avc1.640033,hvc1.1.6.L153.B0"
    /// No fMP4 within this after the handshake means the negotiation failed - the PWA draws the
    /// same conclusion at 3s. Well under the model's 12s startup deadline, so the failure carries
    /// a cause instead of a timeout. Injectable so tests don't wait it out.
    private let handshakeDeadlineInterval: Duration
    /// How far behind the newest sample playback may drift before snapping back to the live edge.
    private static let maximumLatency = CMTime(value: 3, timescale: 1)
    private static let liveEdgeOffset = CMTime(value: 1, timescale: 2)

    init(
        streamName: String,
        client: FrigateClient,
        makeChannel: MakeChannel? = nil,
        handshakeDeadline: Duration = .seconds(4)
    ) {
        self.transport = .mse(streamName: streamName)
        self.streamName = streamName
        self.client = client
        self.makeChannel = makeChannel ?? Self.openSocket
        self.handshakeDeadlineInterval = handshakeDeadline
        synchronizer.addRenderer(renderer)
    }

    private nonisolated static func openSocket(client: FrigateClient, src: String) async throws -> any MediaChannel {
        let socket = try await client.liveSocket(for: .mseWebSocket(src: src))
        await socket.start()
        return socket
    }

    var view: AnyView {
        AnyView(SampleBufferVideoView(view: displayView))
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        connectionEpoch += 1
        let epoch = connectionEpoch
        state = .connecting
        observeRendererFailure()
        tasks.append(Task { await self.connect(epoch: epoch) })
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    func stop() {
        isStarted = false
        hasPlayed = false
        hasVideo = false
        receivedMedia = false
        clockStarted = false
        lastSampleAt = nil
        videoSize = nil
        track = nil
        demuxer = FMP4Demuxer()

        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        sampleWatchdog.cancel()
        rendererStatusObservation = nil

        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()

        if let channel {
            self.channel = nil
            Task { await channel.close() }
        }

        synchronizer.setRate(0, time: .zero)
        // Remove the last picture too, so the still-refreshing snapshot underneath becomes the
        // picture again instead of hiding behind a stale frame.
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)

        state = .idle
    }

    /// Same contract as the WebRTC player: transitions on a stopped player are dropped, because
    /// a task parked on an `await` can outlive the `stop()` that cancelled it.
    private func transition(to newState: LivePlayerState) {
        guard isStarted else { return }
        state = newState
    }

    private func isStale(_ epoch: Int) -> Bool {
        !isStarted || epoch != connectionEpoch
    }

    // MARK: Connection

    private func connect(epoch: Int) async {
        do {
            let channel = try await makeChannel(client, streamName)
            guard !isStale(epoch) else {
                await channel.close()
                return
            }
            self.channel = channel
            try await channel.send(Self.handshakeRequest())
            guard !isStale(epoch) else { return }
            LiveLog.logger.info("mse handshake sent src=\(self.streamName, privacy: .public)")
            armHandshakeDeadline()
            tasks.append(Task { await self.consume(channel, epoch: epoch) })
        } catch {
            LiveLog.logger.error("mse connect failed src=\(self.streamName, privacy: .public) error=\(String(describing: error), privacy: .public)")
            transition(to: .failed(.signalingFailed))
        }
    }

    private func consume(_ channel: any MediaChannel, epoch: Int) async {
        for await frame in await channel.frames() {
            guard !isStale(epoch) else { return }
            switch frame {
            case .text(let json):
                handleText(json)
            case .data(let data):
                do {
                    try ingest(data)
                } catch {
                    LiveLog.logger.error("mse demux failed src=\(self.streamName, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    transition(to: .failed(.decodeFailed))
                    return
                }
            }
        }
        guard !isStale(epoch) else { return }
        // Unlike WebRTC signaling, this socket *is* the media path, so it closing is always the
        // end of the stream - the only question is what to call it.
        LiveLog.logger.info("mse stream ended src=\(self.streamName, privacy: .public)")
        transition(to: .failed(hasPlayed ? .connectionLost : .signalingFailed))
    }

    private func handleText(_ json: String) {
        // The only text expected is the mse codec ack; anything else is another protocol's
        // traffic on the shared socket API, dropped exactly as the WebRTC side drops ours.
        guard let ack = Self.decodeHandshakeAck(json) else { return }
        LiveLog.logger.info("mse negotiated src=\(self.streamName, privacy: .public) codecs=\(ack, privacy: .public)")
    }

    private func ingest(_ data: Data) throws {
        receivedMedia = true
        handshakeDeadline?.cancel()
        handshakeDeadline = nil

        for event in try demuxer.append(data) {
            switch event {
            case .track(let track):
                self.track = track
                let dimensions = CMVideoFormatDescriptionGetDimensions(track.formatDescription)
                videoSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
                LiveLog.logger.info("mse track src=\(self.streamName, privacy: .public) \(dimensions.width, privacy: .public)x\(dimensions.height, privacy: .public) timescale=\(track.timescale, privacy: .public)")
            case .samples(let samples):
                try enqueue(samples)
            }
        }
    }

    private func enqueue(_ samples: [FMP4Demuxer.Sample]) throws {
        guard let track else { throw FMP4Demuxer.DemuxError.malformed("samples before init segment") }
        guard let first = samples.first else { return }
        lastSampleAt = .now

        for sample in samples {
            renderer.enqueue(try VideoSampleBufferFactory.make(sample, track: track))
        }

        if !clockStarted {
            clockStarted = true
            synchronizer.setRate(1, time: CMTime(value: first.presentationTime, timescale: track.timescale))
        } else if let last = samples.last {
            correctDrift(newest: CMTime(value: last.presentationTime, timescale: track.timescale))
        }
        markVideoArrived()
    }

    /// Keeps playback pinned near the live edge. Network hiccups leave the buffer ahead of the
    /// clock; playing that backlog out in real time means watching the past, so jump - the same
    /// call the PWA makes on iOS for the same reason.
    private func correctDrift(newest: CMTime) {
        let behind = newest - synchronizer.currentTime()
        guard behind > Self.maximumLatency else { return }
        LiveLog.logger.info("mse jumping to live edge src=\(self.streamName, privacy: .public) behind=\(behind.seconds, privacy: .public)s")
        synchronizer.setRate(1, time: newest - Self.liveEdgeOffset)
    }

    /// `.playing` here means samples are flowing into a healthy decode pipeline - one honesty
    /// notch below the WebRTC tier's decoded-pixels signal, because this pipeline reports decode
    /// problems only through the renderer failing. That failure path flips the state within a
    /// frame or two, so a lie has no time to persist.
    private func markVideoArrived() {
        guard !hasVideo else { return }
        LiveLog.logger.info("mse first samples src=\(self.streamName, privacy: .public)")
        hasVideo = true
        hasPlayed = true
        startSampleWatchdog()
        transition(to: .playing)
    }

    private func startSampleWatchdog() {
        sampleWatchdog.start(
            lastFrameAt: { [weak self] in self?.lastSampleAt },
            onStall: { [weak self] in
                guard let self else { return }
                LiveLog.logger.info("mse samples stopped src=\(self.streamName, privacy: .public)")
                self.hasVideo = false
                self.transition(to: .stalled)
            }
        )
    }

    /// The renderer failing is the pipeline's word that these bytes cannot be played here - an
    /// unsupported profile, a corrupt stream. Structural, so it maps to `.decodeFailed` and the
    /// model escalates rather than retrying the same bytes.
    private func observeRendererFailure() {
        rendererStatusObservation = renderer.observe(\.status) { [weak self] renderer, _ in
            guard renderer.status == .failed else { return }
            let description = renderer.error.map(String.init(describing:)) ?? "unknown"
            Task { @MainActor [weak self] in
                guard let self else { return }
                LiveLog.logger.error("mse renderer failed src=\(self.streamName, privacy: .public) error=\(description, privacy: .public)")
                self.transition(to: .failed(.decodeFailed))
            }
        }
    }

    /// No media after the handshake means go2rtc had nothing it could send for our codec list -
    /// or never understood us at all. Either way the socket is open and useless.
    private func armHandshakeDeadline() {
        handshakeDeadline?.cancel()
        let interval = handshakeDeadlineInterval
        handshakeDeadline = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self, !self.receivedMedia else { return }
            LiveLog.logger.error("mse handshake produced no media src=\(self.streamName, privacy: .public)")
            self.transition(to: .failed(.signalingFailed))
        }
    }

    // MARK: Wire format

    private nonisolated struct Envelope: Codable {
        let type: String
        let value: String
    }

    nonisolated static func handshakeRequest() -> String {
        let envelope = Envelope(type: "mse", value: offeredCodecs)
        // Encoding two plain strings cannot fail; a crash here would be a compiler bug's problem.
        let data = (try? JSONEncoder().encode(envelope)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The negotiated codec string from an `mse` ack, `nil` for any other message.
    nonisolated static func decodeHandshakeAck(_ json: String) -> String? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)),
              envelope.type == "mse"
        else { return nil }
        return envelope.value
    }
}
