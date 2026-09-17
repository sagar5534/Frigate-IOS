import Foundation

/// Watches a "when did the last frame arrive?" signal and reports when it goes quiet - the
/// mechanism behind every tier's `.stalled` detection, shared so three players don't each carry
/// their own copy of the same loop.
///
/// Fire-once by design: after `onStall` the watchdog is disarmed, and whoever recovers the stream
/// re-arms it by calling `start` again - the same rule as the liveness flags it guards, which are
/// set on a *first* frame, not on every frame.
@MainActor
final class FrameLivenessWatchdog {
    private var task: Task<Void, Never>?
    private let interval: Duration

    /// `interval` is both the polling cadence and the longest silence tolerated: generous enough
    /// for a low-frame-rate camera and a bad moment on wifi, short enough that a frozen picture
    /// is caught before anyone trusts it.
    init(interval: Duration = .seconds(5)) {
        self.interval = interval
    }

    /// (Re)arms the watchdog. `lastFrameAt` is sampled every tick; returning `nil` means the
    /// liveness source has been reset and the watchdog retires quietly - whoever reset it owns
    /// starting the next one.
    func start(
        lastFrameAt: @escaping @MainActor () -> ContinuousClock.Instant?,
        onStall: @escaping @MainActor () -> Void
    ) {
        task?.cancel()
        let interval = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                guard let lastFrameAt = lastFrameAt() else { return }
                if ContinuousClock.now - lastFrameAt > interval {
                    self?.task = nil
                    onStall()
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
