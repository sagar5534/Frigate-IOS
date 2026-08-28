import WebRTC
import XCTest
@testable import Frigate

/// The liveness signal behind `.playing` and the frame watchdog.
///
/// These exist because this exact mechanism produced three separate bugs in P4, all the same shape:
/// a signal that fires **once** mistaken for one that fires continuously. First it hung off a view's
/// rendering and never fired at all; then the watchdog read a timestamp only written on the first
/// frame, so it stalled healthy streams; then clearing the player's flag without re-arming this
/// observer latched it false forever, leaving "Reconnecting" over moving video.
final class VideoFrameObserverTests: XCTestCase {
    /// libwebrtc hands over real `RTCVideoFrame`s; the observer only checks for nil, so any frame
    /// with a valid buffer exercises the same path.
    private func makeFrame() -> RTCVideoFrame {
        RTCVideoFrame(
            buffer: RTCI420Buffer(width: 16, height: 16),
            rotation: ._0,
            timeStampNs: 0
        )
    }

    func testFirstFrameIsReportedExactlyOnce() {
        var reports = 0
        let observer = VideoFrameObserver(onFirstFrame: { reports += 1 }, onSize: { _ in })

        for _ in 0..<5 {
            observer.renderFrame(makeFrame())
        }

        XCTAssertEqual(reports, 1, "only the first frame is news; the rest are the stream working")
    }

    func testANilFrameIsNotAFrame() {
        var reports = 0
        let observer = VideoFrameObserver(onFirstFrame: { reports += 1 }, onSize: { _ in })

        observer.renderFrame(nil)

        XCTAssertEqual(reports, 0)
        XCTAssertNil(observer.lastFrameAt)
    }

    /// The watchdog samples this rather than being pushed to, so *every* frame has to move it -
    /// updating only on the first would make a healthy stream look stalled seconds later.
    func testEveryFrameRefreshesTheLivenessTimestamp() async {
        let observer = VideoFrameObserver(onFirstFrame: {}, onSize: { _ in })

        observer.renderFrame(makeFrame())
        let afterFirst = try? XCTUnwrap(observer.lastFrameAt)
        try? await Task.sleep(for: .milliseconds(5))
        observer.renderFrame(makeFrame())
        let afterSecond = try? XCTUnwrap(observer.lastFrameAt)

        XCTAssertNotNil(afterFirst)
        XCTAssertNotNil(afterSecond)
        XCTAssertGreaterThan(afterSecond!, afterFirst!, "a later frame must move the timestamp")
    }

    /// The fix for the latch bug. After a drop the player calls `reset()`, and the next decoded
    /// frame has to count as a fresh arrival - otherwise nothing can ever restore `.playing` and a
    /// recovered stream is torn down while it is visibly working.
    func testResetReArmsFirstFrameReportingSoARecoveredStreamCanPlayAgain() {
        var reports = 0
        let observer = VideoFrameObserver(onFirstFrame: { reports += 1 }, onSize: { _ in })

        observer.renderFrame(makeFrame())
        XCTAssertEqual(reports, 1)

        observer.reset()
        XCTAssertNil(observer.lastFrameAt, "reset also clears liveness, so the watchdog stands down")

        observer.renderFrame(makeFrame())
        XCTAssertEqual(reports, 2, "a frame after reset must report again")
        XCTAssertNotNil(observer.lastFrameAt)
    }

    func testSizeIsForwardedAndDegenerateSizesIgnored() {
        var sizes: [CGSize] = []
        let observer = VideoFrameObserver(onFirstFrame: {}, onSize: { sizes.append($0) })

        observer.setSize(CGSize(width: 0, height: 0))
        observer.setSize(CGSize(width: 1600, height: 0))
        observer.setSize(CGSize(width: 1600, height: 1200))
        observer.setSize(CGSize(width: 640, height: 480))

        XCTAssertEqual(sizes, [CGSize(width: 1600, height: 1200), CGSize(width: 640, height: 480)],
                       "a mid-stream resolution change is real news; a zero size is not")
    }
}
