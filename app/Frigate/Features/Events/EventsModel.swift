import Foundation
import Observation

/// Drives the Events timeline: loads recent review segments and exposes them newest-first.
@MainActor
@Observable
final class EventsModel {
    enum State: Equatable {
        case loading
        case loaded([ReviewSegment])
        case failed
    }

    private(set) var state: State = .loading

    private let client: FrigateClient

    init(client: FrigateClient) {
        self.client = client
    }

    /// Fetches the last 24 hours of activity. Safe to call again (pull-to-refresh): keeps the
    /// current list on screen while refreshing rather than flashing back to a full-screen spinner.
    func load() async {
        if !state.hasSegments {
            state = .loading
        }
        do {
            let now = Date().timeIntervalSince1970
            let segments = try await client.fetchReviews(before: now, after: now - 24 * 3600)
            state = .loaded(segments.sorted { $0.startTime > $1.startTime })
        } catch {
            state = .failed
        }
    }
}

private extension EventsModel.State {
    var hasSegments: Bool {
        if case .loaded = self { true } else { false }
    }
}
