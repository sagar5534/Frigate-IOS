import Foundation
import Observation

/// Drives the Recent Activity strip: the last hour of unreviewed alert-severity segments for the
/// cameras on screen, newest first, refreshed on a timer.
///
/// Mirrors what Frigate's own PWA shows above its live grid (`LiveDashboardView`): the same
/// `severity=alert&reviewed=0&limit=10` query, and the same client-side "started within the last
/// hour" cut that the server has no parameter for. The PWA drives its refresh off a websocket;
/// we don't have one yet, so this polls - a small JSON response every 30s, against a window
/// measured in hours.
@MainActor
@Observable
final class RecentActivityModel {
    private(set) var segments: [ReviewSegment] = []

    private let client: FrigateClient
    private let cameraNames: [String]
    /// How far back a segment's *start* can be and still count as "recent". Matches the PWA's
    /// one-hour cut.
    private let window: TimeInterval
    private let fetchLimit: Int
    private let now: () -> Date
    private var refreshTask: Task<Void, Never>?

    init(
        client: FrigateClient,
        cameraNames: [String],
        window: TimeInterval = 3600,
        fetchLimit: Int = 10,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.cameraNames = cameraNames
        self.window = window
        self.fetchLimit = fetchLimit
        self.now = now
    }

    /// Fetches once immediately, then repeats every `interval` until `stopAutoRefresh()`. Same
    /// contract as `CameraGridModel.startAutoRefresh`: this spawns an unstructured `Task` that is
    /// NOT torn down with the view's `.task`, so callers must pair it with `stopAutoRefresh()` in
    /// `.onDisappear`. The `refreshTask == nil` guard just stops a second loop starting if `.task`
    /// re-runs while one is already going.
    func startAutoRefresh(interval: Duration = .seconds(30)) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        do {
            let fetched = try await client.fetchReviews(
                cameras: cameraNames,
                severity: .alert,
                limit: fetchLimit,
                reviewed: false
            )
            guard !Task.isCancelled else { return }
            publish(fetched)
        } catch {
            guard !Task.isCancelled else { return }
            // A transient poll failure doesn't blank a populated strip - same rule as
            // `SnapshotState.advanced` uses for camera snapshots. But the recency cut is still
            // re-applied to what we already have, so cards age out of the window on schedule
            // rather than sitting there indefinitely while the server is unreachable.
            publish(segments)
        }
    }

    /// `ReviewDetailView`'s `onUpdate` handler. Marking a segment reviewed on the detail screen
    /// takes it out of the strip's query, so drop it here too rather than waiting up to 30s for
    /// the next poll to notice.
    func apply(_ updated: ReviewSegment) {
        if updated.hasBeenReviewed {
            segments.removeAll { $0.id == updated.id }
        } else if let index = segments.firstIndex(where: { $0.id == updated.id }) {
            segments[index] = updated
        }
    }

    private func publish(_ fetched: [ReviewSegment]) {
        let cutoff = now().timeIntervalSince1970 - window
        let filtered = fetched
            .filter { $0.startTime > cutoff && !$0.hasBeenReviewed }
            .sorted { $0.startTime > $1.startTime }
        // Observation fires on assignment, not on change. Without this guard a poll that returns
        // exactly what's already on screen would still invalidate the strip, and re-identifying
        // the cards can restart their video playback.
        guard filtered != segments else { return }
        segments = filtered
    }
}
