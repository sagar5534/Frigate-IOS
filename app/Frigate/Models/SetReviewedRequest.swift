import Foundation

/// Body for `POST /api/reviews/viewed`. The server accepts a list even for a single segment.
struct SetReviewedRequest: Encodable {
    let ids: [String]
    let reviewed: Bool
}
