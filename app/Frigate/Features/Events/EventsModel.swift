import Foundation
import Observation

/// Drives the Events timeline: loads review segments matching the current `filters` and exposes
/// them newest-first.
@MainActor
@Observable
final class EventsModel {
    enum State: Equatable {
        case loading
        case loaded([ReviewSegment])
        case failed
    }

    private(set) var state: State = .loading
    var filters = EventFilters()

    private let client: FrigateClient

    init(client: FrigateClient) {
        self.client = client
    }

    /// Fetches activity matching `filters`. Safe to call again (pull-to-refresh, or a filter
    /// change): keeps the current list on screen while refreshing rather than flashing back to a
    /// full-screen spinner. Bails out without touching `state` if the surrounding task was
    /// cancelled (e.g. `.task(id:)` starting a newer load for a filter change made mid-fetch) so a
    /// stale result can't clobber a fresher one.
    func load() async {
        if !state.hasSegments {
            state = .loading
        }
        let bounds = filters.timeRange.bounds()
        do {
            let segments = try await client.fetchReviews(
                cameras: Array(filters.cameras),
                labels: Array(filters.labels),
                severity: filters.severity,
                before: bounds.before,
                after: bounds.after
            )
            guard !Task.isCancelled else { return }
            state = .loaded(segments.sorted { $0.startTime > $1.startTime })
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed
        }
    }

    /// Reflects a change made on the detail screen (e.g. mark reviewed/unreviewed) back into the
    /// loaded list, so returning to it shows the up-to-date segment without a full reload.
    func updateSegment(_ updated: ReviewSegment) {
        guard case .loaded(var segments) = state,
              let index = segments.firstIndex(where: { $0.id == updated.id })
        else { return }
        segments[index] = updated
        state = .loaded(segments)
    }
}

private extension EventsModel.State {
    var hasSegments: Bool {
        if case .loaded = self { true } else { false }
    }
}
