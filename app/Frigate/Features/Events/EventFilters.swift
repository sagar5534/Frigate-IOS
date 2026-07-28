import Foundation

/// User-selected filters driving the Events timeline query. Empty `cameras`/`labels` mean "all"
/// cameras/labels (matches `Endpoint.review`'s own "omit when empty" behavior); `severity == nil`
/// means both alerts and detections.
struct EventFilters: Equatable {
    var cameras: Set<String> = []
    var labels: Set<String> = []
    var severity: ReviewSegment.Severity?
    var timeRange: TimeRange = .last24Hours

    enum TimeRange: String, CaseIterable, Identifiable, Equatable {
        case last24Hours = "Last 24 Hours"
        case today = "Today"
        case last7Days = "Last 7 Days"

        var id: String { rawValue }

        /// `(after, before)` unix-second bounds anchored to `now`. Always return both together -
        /// the server re-defaults a missing `after` to "24h before now", so passing only `before`
        /// silently produces the wrong window (see `docs/plans/P3-events-timeline.md`).
        func bounds(now: Date = Date()) -> (after: Double, before: Double) {
            let before = now.timeIntervalSince1970
            switch self {
            case .last24Hours:
                return (before - 24 * 3600, before)
            case .today:
                return (Calendar.current.startOfDay(for: now).timeIntervalSince1970, before)
            case .last7Days:
                return (before - 7 * 24 * 3600, before)
            }
        }
    }

    var isDefault: Bool { self == EventFilters() }
}
