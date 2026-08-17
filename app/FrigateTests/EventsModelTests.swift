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

    /// A page that looks "full" to `EventsModel` (>= its private page size of 100), so
    /// `hasMorePages` stays `true` after loading it and a follow-up `loadMore()` actually fires a
    /// request instead of no-opping. `startingAt` is the oldest (lowest) `start_time` in the page.
    private func fullPageJSON(idPrefix: String, startingAt: Double) -> Data {
        let entries = (0..<100).map { segmentJSON(id: "\(idPrefix)\($0)", startTime: startingAt + Double($0)) }
        return Data("[\(entries.joined(separator: ","))]".utf8)
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

    // MARK: loadMore

    @MainActor
    func testLoadMoreAppendsOlderSegmentsAndKeepsNewestFirstOrder() async {
        let firstPage = fullPageJSON(idPrefix: "p", startingAt: 300) // times 300...399
        let olderPage = Data("[\(segmentJSON(id: "older", startTime: 100))]".utf8)
        let sequence = ResponseSequence([(200, firstPage), (200, olderPage)])
        MockURLProtocol.requestHandler = { request in
            let (status, body) = sequence.next()
            return (self.httpResponse(request.url!, status), body)
        }

        let model = EventsModel(client: makeClient())
        await model.load()
        XCTAssertTrue(model.hasMorePages, "a full page should leave more pages to fetch")

        await model.loadMore()

        guard case .loaded(let segments) = model.state else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(segments.count, 101)
        XCTAssertEqual(segments.last?.id, "older", "the older page should sort to the end")
        XCTAssertFalse(model.isLoadingMore)
    }

    @MainActor
    func testLoadMoreSendsBothBeforeAndAfterAnchoredToTheOldestLoadedSegment() async {
        let firstPage = fullPageJSON(idPrefix: "p", startingAt: 300) // oldest start_time is 300
        var capturedQuery: [String: String] = [:]
        let sequence = ResponseSequence([(200, firstPage), (200, Data("[]".utf8))])
        MockURLProtocol.requestHandler = { request in
            let (status, body) = sequence.next()
            if body == Data("[]".utf8) {
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                capturedQuery = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            }
            return (self.httpResponse(request.url!, status), body)
        }

        let model = EventsModel(client: makeClient())
        await model.load()
        await model.loadMore()

        XCTAssertEqual(capturedQuery["before"], "300.0")
        XCTAssertNotNil(capturedQuery["after"])
    }

    @MainActor
    func testLoadMoreDedupesSegmentsAlreadyInTheList() async {
        let firstPage = fullPageJSON(idPrefix: "p", startingAt: 300) // includes "p0" at time 300
        // Overlapping window returns the boundary segment again alongside one genuinely new one.
        let olderPage = Data("[\(segmentJSON(id: "p0", startTime: 300)),\(segmentJSON(id: "new", startTime: 100))]".utf8)
        let sequence = ResponseSequence([(200, firstPage), (200, olderPage)])
        MockURLProtocol.requestHandler = { request in
            let (status, body) = sequence.next()
            return (self.httpResponse(request.url!, status), body)
        }

        let model = EventsModel(client: makeClient())
        await model.load()
        await model.loadMore()

        guard case .loaded(let segments) = model.state else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(segments.count, 101, "the duplicate p0 should not be counted twice")
        XCTAssertEqual(segments.filter { $0.id == "p0" }.count, 1)
        XCTAssertTrue(segments.contains { $0.id == "new" })
    }

    @MainActor
    func testLoadMoreStopsPaginatingWhenNothingNewComesBack() async {
        let firstPage = fullPageJSON(idPrefix: "p", startingAt: 300)
        // A genuinely full (100-item) page that is entirely duplicates of the first page - the
        // scenario the empty-newSegments guard exists for. A *short* duplicate page wouldn't
        // distinguish this guard from the ordinary "page.count >= pageSize" short-page check
        // (both would report hasMorePages == false anyway), so this must be full-sized to prove
        // the guard - not just a short page - is what stops pagination here.
        let olderPage = firstPage
        let sequence = ResponseSequence([(200, firstPage), (200, olderPage)])
        MockURLProtocol.requestHandler = { request in
            let (status, body) = sequence.next()
            return (self.httpResponse(request.url!, status), body)
        }

        let model = EventsModel(client: makeClient())
        await model.load()
        await model.loadMore()

        XCTAssertFalse(model.hasMorePages)

        guard case .loaded(let segments) = model.state else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(segments.count, 100, "nothing new should have been appended")
    }

    @MainActor
    func testLoadMoreSetsHasMorePagesFalseWhenPageIsShort() async {
        let firstPage = fullPageJSON(idPrefix: "p", startingAt: 300)
        let shortOlderPage = Data("[\(segmentJSON(id: "older", startTime: 100))]".utf8)
        let sequence = ResponseSequence([(200, firstPage), (200, shortOlderPage)])
        MockURLProtocol.requestHandler = { request in
            let (status, body) = sequence.next()
            return (self.httpResponse(request.url!, status), body)
        }

        let model = EventsModel(client: makeClient())
        await model.load()
        await model.loadMore()

        XCTAssertFalse(model.hasMorePages)
    }

    @MainActor
    func testLoadMoreIsNoOpBeforeAnyDataHasLoaded() async {
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return (self.httpResponse(request.url!, 200), Data("[]".utf8))
        }

        let model = EventsModel(client: makeClient())
        await model.loadMore()

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(model.state, .loading)
    }

    @MainActor
    func testLoadMoreIsNoOpOnceHasMorePagesIsFalse() async {
        let firstPage = fullPageJSON(idPrefix: "p", startingAt: 300)
        let shortOlderPage = Data("[\(segmentJSON(id: "older", startTime: 100))]".utf8)
        var requestCount = 0
        let sequence = ResponseSequence([(200, firstPage), (200, shortOlderPage)])
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            let (status, body) = sequence.next()
            return (self.httpResponse(request.url!, status), body)
        }

        let model = EventsModel(client: makeClient())
        await model.load()
        await model.loadMore()
        XCTAssertFalse(model.hasMorePages)
        let countAfterExhausted = requestCount

        await model.loadMore()

        XCTAssertEqual(requestCount, countAfterExhausted, "no further request once hasMorePages is false")
    }

    @MainActor
    func testLoadResetsHasMorePagesToTrueOnANewLoad() async {
        let firstPage = fullPageJSON(idPrefix: "p", startingAt: 300)
        let shortOlderPage = Data("[\(segmentJSON(id: "older", startTime: 100))]".utf8)
        let sequence = ResponseSequence([(200, firstPage), (200, shortOlderPage), (200, firstPage)])
        MockURLProtocol.requestHandler = { request in
            let (status, body) = sequence.next()
            return (self.httpResponse(request.url!, status), body)
        }

        let model = EventsModel(client: makeClient())
        await model.load()
        await model.loadMore()
        XCTAssertFalse(model.hasMorePages)

        await model.load()

        XCTAssertTrue(model.hasMorePages, "a fresh full page should reopen pagination")
    }
}
