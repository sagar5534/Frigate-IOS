import Foundation
import Observation

/// Drives the Events timeline: loads review segments matching the current `filters` and exposes
/// them newest-first, with older pages fetched on demand as the user scrolls.
@MainActor
@Observable
final class EventsModel {
    enum State: Equatable {
        case loading
        case loaded([ReviewSegment])
        case failed
    }

    private(set) var state: State = .loading
    private(set) var isLoadingMore = false
    private(set) var hasMorePages = true
    var filters = EventFilters()

    private let client: FrigateClient
    private let pageSize = 100
    /// Rolling lower bound subtracted from the oldest loaded segment for each "load older" page.
    /// A fixed page size alone isn't enough to page back through time: the server re-defaults a
    /// missing `after` to "24h before now", so every page's `after` must be sent explicitly too
    /// (see `docs/plans/P3-events-timeline.md`).
    private let pageWindow: TimeInterval = 7 * 24 * 3600

    init(client: FrigateClient) {
        self.client = client
    }

    /// Fetches the newest page matching `filters`. Safe to call again (pull-to-refresh, or a
    /// filter change): keeps the current list on screen while refreshing rather than flashing back
    /// to a full-screen spinner. Bails out without touching `state` if the surrounding task was
    /// cancelled (e.g. `.task(id:)` starting a newer load for a filter change made mid-fetch) so a
    /// stale result can't clobber a fresher one.
    func load() async {
        if !state.hasSegments {
            state = .loading
        }
        hasMorePages = true
        let bounds = filters.timeRange.bounds()
        do {
            let segments = try await client.fetchReviews(
                cameras: Array(filters.cameras),
                labels: Array(filters.labels),
                severity: filters.severity,
                before: bounds.before,
                after: bounds.after,
                limit: pageSize
            )
            guard !Task.isCancelled else { return }
            state = .loaded(segments.sorted { $0.startTime > $1.startTime })
            hasMorePages = segments.count >= pageSize
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed
        }
    }

    /// Fetches an older page beyond what's currently loaded and appends it. Call when the last
    /// row scrolls into view. No-ops while already loading, before the first page has loaded, or
    /// once a page has come back with nothing new (no more history worth fetching).
    func loadMore() async {
        guard case .loaded(let segments) = state,
              let oldest = segments.map(\.startTime).min(),
              hasMorePages, !isLoadingMore
        else { return }

        // This fetch isn't wrapped in a Task the caller cancels on filter change (unlike `load()`
        // via `.task(id:)`), so guard explicitly: if filters changed while this was in flight,
        // the response belongs to a query that's no longer current and must not be spliced in.
        let requestedFilters = filters

        isLoadingMore = true
        defer { isLoadingMore = false }

        let before = oldest
        let after = before - pageWindow
        do {
            let page = try await client.fetchReviews(
                cameras: Array(requestedFilters.cameras),
                labels: Array(requestedFilters.labels),
                severity: requestedFilters.severity,
                before: before,
                after: after,
                limit: pageSize
            )
            guard filters == requestedFilters, case .loaded(var current) = state else { return }
            let existingIDs = Set(current.map(\.id))
            let newSegments = page.filter { !existingIDs.contains($0.id) }
            // If nothing new came back, treat this as the end of history even if the raw page was
            // full - otherwise `oldest` never moves and the next scroll-triggered call would
            // re-fetch the exact same window forever.
            guard !newSegments.isEmpty else {
                hasMorePages = false
                return
            }
            current.append(contentsOf: newSegments)
            current.sort { $0.startTime > $1.startTime }
            state = .loaded(current)
            hasMorePages = page.count >= pageSize
        } catch {
            // Leave the list as-is; this is a background pagination fetch, not the primary load -
            // scrolling again (or pull-to-refresh) naturally retries it.
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
