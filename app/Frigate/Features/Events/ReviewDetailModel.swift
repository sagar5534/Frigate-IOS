import Foundation
import Observation

/// Backs the review detail screen: holds the segment being viewed and toggles its reviewed
/// state, reporting the change back to the timeline via `onUpdate`.
@MainActor
@Observable
final class ReviewDetailModel {
    private(set) var segment: ReviewSegment
    private(set) var isUpdatingReviewed = false
    private(set) var errorMessage: String?

    private let client: FrigateClient
    private let onUpdate: (ReviewSegment) -> Void

    init(segment: ReviewSegment, client: FrigateClient, onUpdate: @escaping (ReviewSegment) -> Void) {
        self.segment = segment
        self.client = client
        self.onUpdate = onUpdate
    }

    func toggleReviewed() async {
        let newValue = !segment.hasBeenReviewed
        isUpdatingReviewed = true
        errorMessage = nil
        defer { isUpdatingReviewed = false }
        do {
            try await client.setReviewed(id: segment.id, reviewed: newValue)
            segment.hasBeenReviewed = newValue
            onUpdate(segment)
        } catch {
            // Leave the segment as-is so the button reflects the server's actual state; surface
            // the failure so a user-initiated write doesn't fail silently (unlike a passive load).
            errorMessage = "Couldn't update. Check your connection and try again."
        }
    }
}
