import Foundation
import Observation

/// Owns one camera's live view: which rung of the ladder to play, the player's lifecycle, the
/// reconnect policy, and what to tell the user when it doesn't work.
///
/// The policy lives here rather than in `WebRTCLivePlayer` so it applies to every tier - when MSE
/// (P4.1) and MJPEG (P4.2) land they inherit reconnect, deadlines and teardown for free.
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
    /// Whether video has ever arrived on this camera in this session. Decides what a later failure
    /// is *about*, which is the difference between useful advice and misleading advice - and what a
    /// pause should be *called*, since nothing can be "reconnecting" that never connected.
    private(set) var hasEverPlayed = false

    /// Timings, injectable so tests don't sleep through them.
    struct Policy {
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

        guard let player = factory.makePlayer(for: ladder, client: client) else {
            // No implemented tier for this camera. Not an error to shout about: the snapshot view
            // behind this is still perfectly good, and until P4.1/P4.2 land this is the honest
            // state for a camera with no go2rtc restream.
            state = .failed(.notAvailable)
            return
        }

        player.onStateChange = { [weak self] newState in
            self?.handle(newState)
        }
        player.onVideoSizeChange = { [weak self] size in
            self?.videoAspectRatio = size.height > 0 ? size.width / size.height : nil
        }
        self.player = player
        state = .connecting
        player.start()
        startDeadline(policy.startupDeadline, reason: .iceFailed)
    }

    /// Full teardown. Idempotent, and safe from `onDisappear`, a scene-phase change or a tab switch.
    func stop() {
        cancelTimers()
        reconnectAttempt = 0
        hasEverPlayed = false
        videoAspectRatio = nil
        player?.onStateChange = nil
        player?.onVideoSizeChange = nil
        player?.stop()
        player = nil
        state = .idle
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

    /// Auto-reconnect, but only for failures where trying again could plausibly work.
    ///
    /// `.iceFailed` is excluded on purpose. It means negotiation succeeded and no candidate pair
    /// ever connected, which is a structural fact about the network - port 8555 is not reachable
    /// from here - and hammering it changes nothing except the battery. That one waits for a person.
    private func scheduleReconnect(after error: LivePlayerError) {
        switch error {
        case .iceFailed, .notAvailable:
            return
        case .signalingFailed, .connectionLost, .noVideo:
            // All three can be transient - a restarting server, a flapping network, a camera coming
            // back up - so they are worth a bounded retry.
            break
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
            // `stop()` is also the user-facing teardown, so it clears both of these. An automatic
            // reconnect is a continuation of the same session, not a fresh one: the attempt count
            // has to survive or the chain never terminates, and `hasEverPlayed` has to survive or a
            // stream that played, dropped and reconnected would report the next silence as
            // "the camera sent no video" instead of a lost connection.
            let attempt = self.reconnectAttempt
            let played = self.hasEverPlayed
            self.stop()
            self.reconnectAttempt = attempt
            self.hasEverPlayed = played
            self.start()
        }
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
