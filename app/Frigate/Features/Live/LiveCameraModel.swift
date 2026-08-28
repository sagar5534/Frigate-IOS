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
    /// is *about*, which is the difference between useful advice and misleading advice.
    private var hasEverPlayed = false

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
    var videoAspectRatio: CGFloat? {
        guard let size = player?.videoSize, size.height > 0 else { return nil }
        return size.width / size.height
    }

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
        player?.onStateChange = nil
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
        reconnectAttempt += 1

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            let attempt = self.reconnectAttempt
            self.stop()
            // `stop()` resets the counter because it is also the user-facing teardown; restore it
            // so an automatic retry chain still terminates.
            self.reconnectAttempt = attempt
            self.start()
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
