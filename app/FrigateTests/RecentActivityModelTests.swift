import XCTest
@testable import Frigate

final class RecentActivityModelTests: XCTestCase {
    private let baseURL = URL(string: "https://nvr.local:8971")!
    /// Fixed "now" for every test, so window arithmetic reads as plain numbers.
    private let now = Date(timeIntervalSince1970: 10_000)

    private func makeClient() -> FrigateClient {
        FrigateClient(baseURL: baseURL, session: mockProtocolSession())
    }

    private func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func segmentJSON(
        id: String,
        startTime: Double,
        camera: String = "front_door",
        reviewed: Bool = false
    ) -> String {
        """
        {
          "id": "\(id)", "camera": "\(camera)", "start_time": \(startTime), "end_time": \(startTime + 30),
          "severity": "alert", "has_been_reviewed": \(reviewed),
          "thumb_path": "/media/frigate/clips/review/thumb-\(camera)-\(id).webp",
          "data": {"detections": [], "objects": ["person"], "sub_labels": [], "zones": [], "audio": []}
        }
        """
    }

    private func page(_ segments: String...) -> Data {
        Data("[\(segments.joined(separator: ","))]".utf8)
    }

    @MainActor
    private func makeModel(
        cameraNames: [String] = ["front_door", "backyard"],
        now: @escaping () -> Date
    ) -> RecentActivityModel {
        RecentActivityModel(client: makeClient(), cameraNames: cameraNames, now: now)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testInitialStateIsEmpty() {
        let model = makeModel(now: { self.now })
        XCTAssertTrue(model.segments.isEmpty)
    }

    // MARK: The one-hour window

    @MainActor
    func testRefreshDropsSegmentsThatStartedBeforeTheWindow() async {
        // 50s ago and ~17m ago are inside the 1h window; ~66m ago is outside it. The server has no
        // parameter for this cut - it's applied client-side, exactly as the PWA does it.
        let json = page(
            segmentJSON(id: "recent", startTime: now.timeIntervalSince1970 - 50),
            segmentJSON(id: "stillRecent", startTime: now.timeIntervalSince1970 - 1_000),
            segmentJSON(id: "tooOld", startTime: now.timeIntervalSince1970 - 4_000)
        )
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), json)
        }

        let model = makeModel(now: { self.now })
        await model.refresh()

        XCTAssertEqual(model.segments.map(\.id), ["recent", "stillRecent"])
    }

    @MainActor
    func testRefreshSortsSegmentsNewestFirst() async {
        let json = page(
            segmentJSON(id: "older", startTime: now.timeIntervalSince1970 - 900),
            segmentJSON(id: "newest", startTime: now.timeIntervalSince1970 - 60),
            segmentJSON(id: "middle", startTime: now.timeIntervalSince1970 - 300)
        )
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), json)
        }

        let model = makeModel(now: { self.now })
        await model.refresh()

        XCTAssertEqual(model.segments.map(\.id), ["newest", "middle", "older"])
    }

    // MARK: Query shape

    @MainActor
    func testRefreshQueriesUnreviewedAlertsForTheGivenCameras() async {
        let capturedURL = CapturedURL()
        MockURLProtocol.requestHandler = { request in
            capturedURL.set(request.url)
            return (self.httpResponse(request.url!, 200), Data("[]".utf8))
        }

        let model = makeModel(cameraNames: ["front_door", "backyard"], now: { self.now })
        await model.refresh()

        guard let url = capturedURL.value,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return XCTFail("expected a request to have been made")
        }
        XCTAssertEqual(components.path, "/api/review")

        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )
        XCTAssertEqual(query["severity"], "alert")
        XCTAssertEqual(query["reviewed"], "0")
        XCTAssertEqual(query["limit"], "10")
        XCTAssertEqual(query["cameras"], "front_door,backyard")
    }

    // MARK: Failure handling

    @MainActor
    func testFailedRefreshKeepsTheSegmentsAlreadyOnScreen() async {
        let attempts = Counter()
        let json = page(segmentJSON(id: "recent", startTime: now.timeIntervalSince1970 - 60))
        MockURLProtocol.requestHandler = { request in
            if attempts.increment() == 1 {
                return (self.httpResponse(request.url!, 200), json)
            }
            throw URLError(.notConnectedToInternet)
        }

        let model = makeModel(now: { self.now })
        await model.refresh()
        XCTAssertEqual(model.segments.map(\.id), ["recent"])

        await model.refresh()
        XCTAssertEqual(
            model.segments.map(\.id),
            ["recent"],
            "a transient poll failure should not blank a populated strip"
        )
    }

    @MainActor
    func testSegmentsStillAgeOutOfTheWindowWhileTheServerIsUnreachable() async {
        let attempts = Counter()
        let json = page(segmentJSON(id: "recent", startTime: now.timeIntervalSince1970 - 60))
        MockURLProtocol.requestHandler = { request in
            if attempts.increment() == 1 {
                return (self.httpResponse(request.url!, 200), json)
            }
            throw URLError(.notConnectedToInternet)
        }

        var currentTime = now
        let model = makeModel(now: { currentTime })
        await model.refresh()
        XCTAssertEqual(model.segments.count, 1)

        // Two hours later the held segment is well outside the window. The fetch still fails, so
        // the only thing that can retire the card is the cutoff being re-applied to what we hold.
        currentTime = now.addingTimeInterval(7_200)
        await model.refresh()
        XCTAssertTrue(model.segments.isEmpty)
    }

    // MARK: apply(_:)

    @MainActor
    func testApplyRemovesASegmentOnceItIsMarkedReviewed() async {
        let json = page(
            segmentJSON(id: "a", startTime: now.timeIntervalSince1970 - 60),
            segmentJSON(id: "b", startTime: now.timeIntervalSince1970 - 120)
        )
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), json)
        }

        let model = makeModel(now: { self.now })
        await model.refresh()

        var reviewed = model.segments.first { $0.id == "a" }!
        reviewed.hasBeenReviewed = true
        model.apply(reviewed)

        XCTAssertEqual(model.segments.map(\.id), ["b"])
    }

    @MainActor
    func testApplyIgnoresASegmentThatIsNotInTheStrip() async {
        let json = page(segmentJSON(id: "a", startTime: now.timeIntervalSince1970 - 60))
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), json)
        }

        let model = makeModel(now: { self.now })
        await model.refresh()

        let stranger = try! JSONDecoder().decode(
            [ReviewSegment].self,
            from: page(segmentJSON(id: "elsewhere", startTime: now.timeIntervalSince1970 - 90))
        )[0]
        model.apply(stranger)

        XCTAssertEqual(model.segments.map(\.id), ["a"])
    }

    // MARK: Auto refresh

    @MainActor
    func testStartAutoRefreshPollsRepeatedlyUntilStopped() async {
        // Same shape as CameraGridModelTests' auto-refresh test: wait on the first fetch, stop,
        // then outlive the interval to prove no further fetch fires.
        let firstFetch = XCTestExpectation(description: "first fetch happened")
        let callCount = CallCount()
        MockURLProtocol.requestHandler = { request in
            callCount.increment()
            if callCount.current == 1 {
                firstFetch.fulfill()
            }
            return (self.httpResponse(request.url!, 200), Data("[]".utf8))
        }

        let model = makeModel(now: { self.now })
        model.startAutoRefresh(interval: .milliseconds(300))
        await fulfillment(of: [firstFetch], timeout: 2)

        model.stopAutoRefresh()
        let countAtStop = callCount.current

        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            callCount.current,
            countAtStop,
            "no more fetches should happen after stopAutoRefresh()"
        )
    }

    @MainActor
    func testStartAutoRefreshIsIdempotent() async {
        let firstFetch = XCTestExpectation(description: "first fetch happened")
        let callCount = CallCount()
        MockURLProtocol.requestHandler = { request in
            callCount.increment()
            if callCount.current == 1 {
                firstFetch.fulfill()
            }
            return (self.httpResponse(request.url!, 200), Data("[]".utf8))
        }

        let model = makeModel(now: { self.now })
        // A second call while a loop is already running must not start a second one - otherwise a
        // `.task` that re-runs would double the poll rate every time.
        model.startAutoRefresh(interval: .seconds(30))
        model.startAutoRefresh(interval: .seconds(30))
        await fulfillment(of: [firstFetch], timeout: 2)

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(callCount.current, 1, "a second startAutoRefresh() should not start a second loop")
        model.stopAutoRefresh()
    }
}

/// Captures the URL of the last request the mock protocol saw, for asserting query shape.
private final class CapturedURL: @unchecked Sendable {
    private var url: URL?
    private let lock = NSLock()

    func set(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        self.url = url
    }

    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }
}

/// Thread-safe call counter exposing its running total, so a test can assert it stops changing.
/// (`Counter` in MockURLProtocol.swift only returns the post-increment value.)
private final class CallCount: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
