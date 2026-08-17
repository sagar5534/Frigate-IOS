import XCTest
@testable import Frigate

final class ReviewDetailModelTests: XCTestCase {
    private let baseURL = URL(string: "https://nvr.local:8971")!

    private func makeClient() -> FrigateClient {
        FrigateClient(baseURL: baseURL, session: mockProtocolSession())
    }

    private func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func makeSegment(hasBeenReviewed: Bool) throws -> ReviewSegment {
        let json = Data("""
        {
          "id": "abc", "camera": "front_door", "start_time": 100.0, "end_time": 130.0,
          "severity": "alert", "has_been_reviewed": \(hasBeenReviewed),
          "thumb_path": "/media/frigate/clips/review/thumb-front_door-abc.webp",
          "data": {"detections": [], "objects": ["person"], "sub_labels": [], "zones": [], "audio": []}
        }
        """.utf8)
        return try JSONDecoder().decode(ReviewSegment.self, from: json)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testToggleReviewedFlipsStateAndNotifiesOnSuccess() async throws {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), Data())
        }

        var updated: ReviewSegment?
        let segment = try makeSegment(hasBeenReviewed: false)
        let model = ReviewDetailModel(segment: segment, client: makeClient()) { updated = $0 }

        await model.toggleReviewed()

        XCTAssertTrue(model.segment.hasBeenReviewed)
        XCTAssertEqual(updated?.hasBeenReviewed, true)
        XCTAssertFalse(model.isUpdatingReviewed)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testToggleReviewedLeavesStateUnchangedOnFailure() async throws {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 500), Data())
        }

        var updateCalled = false
        let segment = try makeSegment(hasBeenReviewed: false)
        let model = ReviewDetailModel(segment: segment, client: makeClient()) { _ in updateCalled = true }

        await model.toggleReviewed()

        XCTAssertFalse(model.segment.hasBeenReviewed)
        XCTAssertFalse(updateCalled)
        XCTAssertFalse(model.isUpdatingReviewed)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testRetryAfterFailureClearsThePriorError() async throws {
        let sequence = ResponseSequence([(500, Data()), (200, Data())])
        MockURLProtocol.requestHandler = { request in
            let (status, body) = sequence.next()
            return (self.httpResponse(request.url!, status), body)
        }

        let segment = try makeSegment(hasBeenReviewed: false)
        let model = ReviewDetailModel(segment: segment, client: makeClient()) { _ in }

        await model.toggleReviewed()
        XCTAssertNotNil(model.errorMessage)

        await model.toggleReviewed()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.segment.hasBeenReviewed)
    }
}
