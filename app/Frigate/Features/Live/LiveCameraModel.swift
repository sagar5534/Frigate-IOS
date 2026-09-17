import Foundation
import Observation
import OSLog

/// Owns one camera's live view: which rung of the ladder to play, the player's lifecycle, the
/// reconnect policy, **escalation down the ladder when a tier fails**, and what to tell the user
/// when nothing works.
///
/// The policy lives here rather than in the players so it applies to every tier identically.
@MainActor
@Observable
final class LiveCameraModel {
    private(set) var state: LivePlayerState = .idle
    private(set) var player: (any LivePlayer)?

    let cameraName: String

    private let client: FrigateClient
    private let ladder: [LiveTransport]
    private let factory: LivePlayerFactory
    private let policy: Policy

    private var reconnectTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// Which rung of the ladder is (or was last) playing. Escalation only ever moves it down;
    /// only a fresh `start()` after `stop()`, or the user's own retry, returns to the top.
    private var rungIndex = 0
    /// Whether video has ever arrived on this camera in this session. Decides what a later failure
    /// is *about*, which is the difference between useful advice and misleading advice - and what a
    /// pause should be *called*, since nothing can be "reconnecting" that never connected.
    private(set) var hasEverPlayed = false

    /// Timings, injectable so tests don't sleep through them.
    nonisolated struct Policy {
        /// How long a connection attempt may sit in `.connecting` before we call it a failure.
        /// libwebrtc's own ICE timeout is far longer - tens of seconds - which is an unacceptable
        /// spinner for someone who just tapped a camera. Failing early with a specific reason beats
        /// being right slowly.
        var startupDeadline: Duration = .seconds(12)
        /// How long a stall may last before it counts as a lost connection worth reconnecting.
        var stallDeadline: Duration = .seconds(8)
        var initialBackoff: Duration = .seconds(1)
        var maximumBackoff: Duration = .seconds(30)
        /// After this many consecutive automatic attempts, stop and wait for the user. Retrying
        /// forever on a camera nobody is looking at is just battery.
        var maximumAttempts = 5
        /// How long a pre-retry session refresh may take before the retry goes ahead without it.
        var sessionRefreshTimeout: Duration = .seconds(5)
    }

    init(
        client: FrigateClient,
        cameraName: String,
        config: FrigateConfig,
        factory: LivePlayerFactory = LivePlayerFactory(),
        policy: Policy = Policy()
    ) {
        self.client = client
        self.cameraName = cameraName
        self.ladder = LiveStreamSource.ladder(camera: cameraName, config: config)
        self.factory = factory
        self.policy = policy
    }

    /// True once live video is genuinely on screen - and therefore when the snapshot poll behind it
    /// is redundant.
    var isPlaying: Bool {
        state == .playing
    }

    /// The stream's aspect ratio once known, so a fullscreen container can be shaped to the video
    /// instead of cropping it to whatever shape the screen happens to be.
    ///
    /// Mirrored into observable state rather than read through to the player on demand: players are
    /// not `@Observable` (SwiftUI cannot observe through an existential), so a computed passthrough
    /// would only ever refresh when some *other* tracked property happened to change - and a camera
    /// that switches resolution mid-stream changes nothing else.
    private(set) var videoAspectRatio: CGFloat?

    /// A failure the user has to act on, as opposed to one we're already retrying.
    var isAwaitingManualRetry: Bool {
        if case .failed = state { return reconnectTask == nil }
        return false
    }

    // MARK: Lifecycle

    func start() {
        guard player == nil else { return }

        guard startRung(from: rungIndex) else {
            // No implemented tier could be built for this camera. Not an error to shout about:
            // the snapshot view behind this is still perfectly good.
            state = .failed(.notAvailable)
            return
        }
    }

    /// Builds and starts the best implemented rung at or below `index`. `false` when none of the
    /// remaining rungs can be built, in which case nothing was changed.
    @discardableResult
    private func startRung(from index: Int) -> Bool {
        guard let (rung, player) = buildRung(from: index) else { return false }
        rungIndex = rung
        attach(player)
        return true
    }

    private func buildRung(from index: Int) -> (Int, any LivePlayer)? {
        for candidate in index..<ladder.count {
            if let player = factory.makePlayer(for: ladder[candidate], client: client) {
                return (candidate, player)
            }
        }
        return nil
    }

    private func attach(_ player: any LivePlayer) {
        player.onStateChange = { [weak self] newState in
            self?.handle(newState)
        }
        player.onVideoSizeChange = { [weak self] size in
            self?.videoAspectRatio = size.height > 0 ? size.width / size.height : nil
        }
        self.player = player
        state = .connecting
        player.start()
        startDeadline(policy.startupDeadline, reason: Self.startupFailure(for: player.transport))
    }

    /// What a hopelessly stuck startup *means* differs by tier: WebRTC stuck in `.connecting` is
    /// the port-8555 media path not connecting, while the origin-riding tiers have nothing but the
    /// server to blame.
    private static func startupFailure(for transport: LiveTransport) -> LivePlayerError {
        if case .webrtc = transport { return .iceFailed }
        return .signalingFailed
    }

    /// Full teardown. Idempotent, and safe from `onDisappear`, a scene-phase change or a tab switch.
    func stop() {
        cancelTimers()
        reconnectAttempt = 0
        rungIndex = 0
        hasEverPlayed = false
        detachPlayer()
        state = .idle
    }

    /// Tears down just the player, leaving the session's bookkeeping (`reconnectAttempt`,
    /// `hasEverPlayed`, `rungIndex`) alone - the piece shared by full stops, reconnects, and
    /// escalations, which differ only in what happens to that bookkeeping.
    private func detachPlayer() {
        player?.onStateChange = nil
        player?.onVideoSizeChange = nil
        player?.stop()
        player = nil
        videoAspectRatio = nil
    }

    /// User-initiated. Resets the backoff, because a person tapping Retry is new information.
    func retry() {
        stop()
        start()
    }

    // MARK: Policy

    private func handle(_ newState: LivePlayerState) {
        state = newState

        switch newState {
        case .playing:
            cancelTimers()
            hasEverPlayed = true
            reconnectAttempt = 0
        case .stalled:
            // Give the transport a chance to recover on its own before tearing anything down; it
            // often does, and a reconnect costs a fresh handshake and a second of black.
            //
            // The reason differs by history, and getting it wrong is worse than saying nothing:
            // a stall before any video ever arrived means the connection succeeded and the camera
            // sent nothing, while a stall after playing means a working stream dropped. Blaming the
            // network for the former would send someone to reconfigure a router that is fine.
            startDeadline(policy.stallDeadline, reason: hasEverPlayed ? .connectionLost : .noVideo)
        case .failed(let error):
            cancelTimers()
            scheduleReconnect(after: error)
        case .connecting, .idle:
            break
        }
    }

    /// The recovery policy: escalate down the ladder when a failure is structural for the tier,
    /// retry in place when it is plausibly transient, and hand over to the user when neither is
    /// left. What each failure gets, and why:
    ///
    /// - `.iceFailed` / `.decodeFailed` - structural facts about the tier (port 8555 unreachable;
    ///   bytes this device can't play). Retrying changes nothing, so escalate immediately; with no
    ///   rung below, wait for a person.
    /// - `.noVideo` - the tier connected and showed nothing. A lower tier is a genuinely different
    ///   source path (MJPEG comes off the detect pipeline, not the restream), so prefer it over
    ///   retrying a tier that already demonstrated silence.
    /// - `.signalingFailed` - one same-rung retry first, because the retry path refreshes a
    ///   possibly-stale session cookie and that fixes the most common cause; if the second attempt
    ///   fails too, escalate.
    /// - `.connectionLost` - this tier demonstrably *worked*, so spend the whole retry budget on it
    ///   before trading down in quality.
    private func scheduleReconnect(after error: LivePlayerError) {
        switch error {
        case .notAvailable:
            return
        case .iceFailed, .decodeFailed:
            _ = escalate()
            return
        case .noVideo:
            if escalate() { return }
        case .signalingFailed:
            if reconnectAttempt >= 1, escalate() { return }
        case .connectionLost:
            if reconnectAttempt >= policy.maximumAttempts, escalate() { return }
        }

        guard reconnectAttempt < policy.maximumAttempts else { return }
        let delay = backoff(for: reconnectAttempt)
        let isFirstAttempt = reconnectAttempt == 0
        reconnectAttempt += 1

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }

            // The WebSocket handshake carries whatever cookie was in the jar and has no 401 retry of
            // its own - unlike every other request, which re-logs-in transparently. An expired
            // session therefore looks like "the server didn't answer". Refresh once before the first
            // retry so a stale cookie self-heals instead of burning the whole budget on a wrong
            // diagnosis.
            if isFirstAttempt, error == .signalingFailed {
                await self.refreshSessionBounded()
            }
            guard !Task.isCancelled else { return }
            self.reconnectTask = nil
            // Deliberately not `stop()` + `start()`: those are the user-facing session boundary
            // and reset the attempt count (the chain would never terminate), `hasEverPlayed`
            // (a later silence would be blamed on the camera instead of the connection), and the
            // rung (a retry of the MJPEG floor would climb back up to re-fail the tiers that
            // already failed). An automatic reconnect replaces only the player.
            self.cancelTimers()
            self.detachPlayer()
            self.startRung(from: self.rungIndex)
        }
    }

    /// Falls to the next implemented rung of the ladder, carrying the session's history
    /// (`hasEverPlayed` drives failure wording) but a fresh retry budget - the new tier hasn't
    /// failed yet. Returns `false` from the bottom rung **without touching anything**: the
    /// reported failure, the failed player, and the spent retry budget all stand, so the caller's
    /// fallback logic sees the world as it was.
    private func escalate() -> Bool {
        guard let (rung, next) = buildRung(from: rungIndex + 1) else { return false }

        let failedTransport = player?.transport
        cancelTimers()
        detachPlayer()
        reconnectAttempt = 0
        rungIndex = rung
        attach(next)
        LiveLog.logger.info("escalating live tier camera=\(self.cameraName, privacy: .public) from=\(String(describing: failedTransport), privacy: .public) to=\(String(describing: self.ladder[rung]), privacy: .public)")
        return true
    }

    /// A session refresh that cannot hold the reconnect hostage.
    ///
    /// `refreshSession()` is an ordinary HTTP round trip on a session using URLSession's 60s
    /// default timeout. Unbounded, an unreachable server would park the reconnect task for a full
    /// minute - and because `isAwaitingManualRetry` is false while that task exists, the user would
    /// stare at a spinner with no Try Again button and no way out. The refresh is best-effort, so
    /// giving up on it early costs nothing: the retry proceeds either way.
    private func refreshSessionBounded() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [client] in await client.refreshSession() }
            group.addTask { [policy] in try? await Task.sleep(for: policy.sessionRefreshTimeout) }
            await group.next()
            group.cancelAll()
        }
    }

    private func backoff(for attempt: Int) -> Duration {
        let doubled = policy.initialBackoff * (1 << attempt)
        return min(doubled, policy.maximumBackoff)
    }

    /// Fails the player if it hasn't reached `.playing` within `duration`.
    private func startDeadline(_ duration: Duration, reason: LivePlayerError) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, !self.isPlaying else { return }
            self.deadlineTask = nil
            self.player?.stop()
            self.handle(.failed(reason))
        }
    }

    private func cancelTimers() {
        deadlineTask?.cancel()
        deadlineTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }
}
