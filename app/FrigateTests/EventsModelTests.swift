import XCTest
@testable import Frigate

final class EventsModelTests: XCTestCase {
    private let baseURL = URL(string: "https://nvr.local:8971")!

    private func makeClient() -> FrigateClient {
        FrigateClient(baseURL: baseURL, session: mockProtocolSession())
    }

    private func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func segmentJSON(id: String, startTime: Double) -> String {
        """
        {
          "id": "\(id)", "camera": "front_door", "start_time": \(startTime), "end_time": \(startTime + 30),
          "severity": "alert", "has_been_reviewed": false,
          "thumb_path": "/media/frigate/clips/review/thumb-front_door-\(id).webp",
          "data": {"detections": [], "objects": ["person"], "sub_labels": [], "zones": [], "audio": []}
        }
        """
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testInitialStateIsLoading() {
        let model = EventsModel(client: makeClient())
        XCTAssertEqual(model.state, .loading)
    }

    @MainActor
    func testLoadSortsSegmentsNewestFirst() async {
        let json = Data("[\(segmentJSON(id: "old", startTime: 100)),\(segmentJSON(id: "new", startTime: 200))]".utf8)
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), json)
        }

        let model = EventsModel(client: makeClient())
        await model.load()

        guard case .loaded(let segments) = model.state else {
            return XCTFail("expected .loaded, got \(model.state)")
        }
        XCTAssertEqual(segments.map(\.id), ["new", "old"])
    }

    @MainActor
    func testLoadSendsBothBeforeAndAfterToAvoidTheServersDefaultWindow() async {
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            capturedQuery = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            return (self.httpResponse(request.url!, 200), Data("[]".utf8))
        }

        let model = EventsModel(client: makeClient())
        await model.load()

        XCTAssertNotNil(capturedQuery["before"])
        XCTAssertNotNil(capturedQuery["after"])
    }

    @MainActor
    func testLoadOnEmptyResultSetsLoadedEmpty() async {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), Data("[]".utf8))
        }

        let model = EventsModel(client: makeClient())
        await model.load()

        XCTAssertEqual(model.state, .loaded([]))
    }

    @MainActor
    func testLoadAppliesCurrentFiltersToTheQuery() async {
        var capturedQuery: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            capturedQuery = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            return (self.httpResponse(request.url!, 200), Data("[]".utf8))
        }

        let model = EventsModel(client: makeClient())
        model.filters.cameras = ["front_door"]
        model.filters.labels = ["person"]
        model.filters.severity = .alert
        await model.load()

        XCTAssertEqual(capturedQuery["cameras"], "front_door")
        XCTAssertEqual(capturedQuery["labels"], "person")
        XCTAssertEqual(capturedQuery["severity"], "alert")
    }

    @MainActor
    func testUpdateSegmentReplacesMatchingSegmentInPlace() async throws {
        let json = Data("[\(segmentJSON(id: "1", startTime: 100))]".utf8)
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), json)
        }

        let model = EventsModel(client: makeClient())
        await model.load()
        guard case .loaded(var segments) = model.state else {
            return XCTFail("expected .loaded after the first load")
        }

        segments[0].hasBeenReviewed = true
        model.updateSegment(segments[0])

        guard case .loaded(let updated) = model.state else {
            return XCTFail("expected .loaded after updateSegment")
        }
        XCTAssertEqual(updated.first?.hasBeenReviewed, true)
    }

    @MainActor
    func testUpdateSegmentForUnknownIdIsANoOp() async throws {
        let json = Data("[\(segmentJSON(id: "1", startTime: 100))]".utf8)
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), json)
        }

        let model = EventsModel(client: makeClient())
        await model.load()

        let unknownJSON = Data(segmentJSON(id: "does-not-exist", startTime: 999).utf8)
        let unknown = try JSONDecoder().decode(ReviewSegment.self, from: unknownJSON)
        model.updateSegment(unknown)

        guard case .loaded(let segments) = model.state else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(segments.map(\.id), ["1"])
    }

    @MainActor
    func testLoadFailureSetsFailedState() async {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 500), Data())
        }

        let model = EventsModel(client: makeClient())
        await model.load()

        XCTAssertEqual(model.state, .failed)
    }
}
