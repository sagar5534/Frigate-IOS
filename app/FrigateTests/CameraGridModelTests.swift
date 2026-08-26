import XCTest
@testable import Frigate

final class CameraGridModelTests: XCTestCase {
    private let baseURL = URL(string: "https://nvr.local:8971")!
    private let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])

    private func makeClient() -> FrigateClient {
        FrigateClient(baseURL: baseURL, session: mockProtocolSession())
    }

    private func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testInitialStateIsLoadingForEveryCamera() {
        let model = CameraGridModel(client: makeClient(), cameraNames: ["front_door", "backyard"])
        XCTAssertEqual(model.snapshots["front_door"], .loading)
        XCTAssertEqual(model.snapshots["backyard"], .loading)
    }

    @MainActor
    func testRefreshAllPopulatesLoadedStateForEachCamera() async {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), self.jpegBytes)
        }

        let model = CameraGridModel(client: makeClient(), cameraNames: ["front_door", "backyard"])
        await model.refreshAll()

        XCTAssertEqual(model.snapshots["front_door"]?.snapshot?.data, jpegBytes)
        XCTAssertEqual(model.snapshots["backyard"]?.snapshot?.data, jpegBytes)
    }

    @MainActor
    func testRefreshAllKeepsCapturedAtWhenBytesAreUnchanged() async {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), self.jpegBytes)
        }

        let firstFetch = Date(timeIntervalSince1970: 1_000)
        let secondFetch = Date(timeIntervalSince1970: 1_010)
        var currentTime = firstFetch
        let model = CameraGridModel(
            client: makeClient(),
            cameraNames: ["front_door"],
            now: { currentTime }
        )

        await model.refreshAll()
        XCTAssertEqual(model.snapshots["front_door"]?.snapshot?.capturedAt, firstFetch)

        currentTime = secondFetch
        await model.refreshAll()
        XCTAssertEqual(
            model.snapshots["front_door"]?.snapshot?.capturedAt,
            firstFetch,
            "identical bytes should not reset the freshness clock"
        )
    }

    @MainActor
    func testRefreshAllAdvancesCapturedAtWhenBytesChange() async {
        let secondJpegBytes = Data([0xFF, 0xD8, 0x00, 0xD9])
        var responseBytes = jpegBytes
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 200), responseBytes)
        }

        let firstFetch = Date(timeIntervalSince1970: 1_000)
        let secondFetch = Date(timeIntervalSince1970: 1_010)
        var currentTime = firstFetch
        let model = CameraGridModel(
            client: makeClient(),
            cameraNames: ["front_door"],
            now: { currentTime }
        )

        await model.refreshAll()
        XCTAssertEqual(model.snapshots["front_door"]?.snapshot?.capturedAt, firstFetch)

        responseBytes = secondJpegBytes
        currentTime = secondFetch
        await model.refreshAll()
        XCTAssertEqual(model.snapshots["front_door"]?.snapshot?.data, secondJpegBytes)
        XCTAssertEqual(model.snapshots["front_door"]?.snapshot?.capturedAt, secondFetch)
    }

    @MainActor
    func testRefreshAllKeepsLastGoodSnapshotOnSubsequentFailure() async {
        var shouldFail = false
        MockURLProtocol.requestHandler = { request in
            shouldFail
                ? (self.httpResponse(request.url!, 500), Data())
                : (self.httpResponse(request.url!, 200), self.jpegBytes)
        }

        let model = CameraGridModel(client: makeClient(), cameraNames: ["front_door"])
        await model.refreshAll()
        XCTAssertEqual(model.snapshots["front_door"]?.snapshot?.data, jpegBytes)

        shouldFail = true
        await model.refreshAll()
        XCTAssertEqual(
            model.snapshots["front_door"]?.snapshot?.data,
            jpegBytes,
            "a failed fetch should not blank out the last good frame"
        )
    }

    @MainActor
    func testRefreshAllMarksCameraFailedOnServerError() async {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 500), Data())
        }

        let model = CameraGridModel(client: makeClient(), cameraNames: ["front_door"])
        await model.refreshAll()

        XCTAssertEqual(model.snapshots["front_door"], .failed)
    }

    @MainActor
    func testStopAutoRefreshStopsFurtherFetches() async {
        // The mock's request handler fires on a background queue (real URLSession/URLProtocol
        // delivery), decoupled from the MainActor timing of the model's refresh loop - racing
        // wall-clock sleeps against it is flaky. Instead: synchronize on the first fetch actually
        // happening via an expectation. The determinism guarantee doesn't depend on stop landing
        // during the loop's sleep (it may still land mid-fetch) - it comes from cancellation
        // preventing the `while` loop from ever re-entering `refreshAll()` afterwards, so at most
        // one fetch can ever occur regardless of exactly when `stopAutoRefresh()` runs. The 300ms
        // interval just keeps the "wait past it and confirm no second fetch" check below fast.
        let firstFetch = XCTestExpectation(description: "first fetch happened")
        let callCount = CallCount()
        MockURLProtocol.requestHandler = { request in
            callCount.increment()
            if callCount.current == 1 {
                firstFetch.fulfill()
            }
            return (self.httpResponse(request.url!, 200), self.jpegBytes)
        }

        let model = CameraGridModel(client: makeClient(), cameraNames: ["front_door"])
        model.startAutoRefresh(interval: .milliseconds(300))
        await fulfillment(of: [firstFetch], timeout: 2)

        model.stopAutoRefresh()
        let countAtStop = callCount.current
        XCTAssertEqual(countAtStop, 1)

        // Outlive the 300ms interval: if stopAutoRefresh() hadn't actually cancelled the loop, a
        // second fetch would have fired well within this window.
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(callCount.current, countAtStop, "no more fetches should happen after stopAutoRefresh()")
    }
}

/// Thread-safe call counter, mirroring `Counter` in MockURLProtocol.swift but exposing the running
/// total (needed here to assert it stops changing after `stopAutoRefresh()`).
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
