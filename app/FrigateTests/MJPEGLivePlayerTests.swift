import UIKit
import XCTest
@testable import Frigate

@MainActor
final class MJPEGLivePlayerTests: XCTestCase {
    private var player: MJPEGLivePlayer?

    override func tearDown() async throws {
        player?.stop()
        player = nil
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    private func makeClient() -> FrigateClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return FrigateClient(baseURL: URL(string: "https://nvr.local:8971")!, session: URLSession(configuration: config))
    }

    private func makePlayer() -> MJPEGLivePlayer {
        let player = MJPEGLivePlayer(camera: "front_door", height: 720, fps: 5, client: makeClient())
        self.player = player
        return player
    }

    /// A real decodable JPEG - UIImage must accept it, or the player rightly never reports frames.
    private func realJPEG(side: CGFloat = 8) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.jpegData(compressionQuality: 0.7)!
    }

    private func multipartBody(_ jpegs: [Data]) -> Data {
        var body = Data()
        for jpeg in jpegs {
            body.append(Data("--frame\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(jpeg)
            body.append(Data("\r\n\r\n".utf8))
        }
        return body
    }

    private func serveMultipart(_ jpegs: [Data], status: Int = 200) {
        let body = multipartBody(jpegs)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "multipart/x-mixed-replace;boundary=frame"]
            )!
            return (response, body)
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    // MARK: Lifecycle contract

    func testNewPlayerIsIdleAndReportsItsTransport() {
        let player = makePlayer()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.transport, .mjpeg(camera: "front_door", height: 720, fps: 5))
    }

    func testStopIsSafeBeforeStartAndWhenRepeated() {
        let player = makePlayer()
        player.stop()
        player.stop()
        XCTAssertEqual(player.state, .idle)
    }

    // MARK: Streaming

    func testFramesReachPlayingWithTheStreamSizeThenEndOfStreamIsALostConnection() async {
        serveMultipart([realJPEG(), realJPEG()])
        let player = makePlayer()
        var observed: [LivePlayerState] = []
        player.onStateChange = { observed.append($0) }
        player.start()

        // The canned body is finite, so a healthy run is: frames play, then the "infinite" stream
        // ends - which for a live feed is a lost connection, not a normal completion.
        await waitUntil("the stream to play and then end") { player.state == .failed(.connectionLost) }
        XCTAssertTrue(observed.contains(.playing), "frames should have played before the end: \(observed)")
    }

    func testVideoSizeComesFromTheDecodedFrame() async {
        serveMultipart([realJPEG(side: 16)])
        let player = makePlayer()
        player.start()

        await waitUntil("the frame size to be reported") { player.videoSize == CGSize(width: 16, height: 16) }
    }

    func testHTTPErrorFailsAsSignalingFailure() async {
        serveMultipart([], status: 503)
        let player = makePlayer()
        player.start()

        await waitUntil("the HTTP failure to surface") { player.state == .failed(.signalingFailed) }
    }

    func testStreamEndingBeforeAnyFrameIsASignalingFailure() async {
        serveMultipart([])  // 200, but no parts at all
        let player = makePlayer()
        player.start()

        await waitUntil("the empty stream to surface") { player.state == .failed(.signalingFailed) }
    }

    // MARK: Boundary parsing

    func testBoundaryIsReadFromTheContentTypeHeader() {
        let response = HTTPURLResponse(
            url: URL(string: "https://nvr.local/api/cam")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": #"multipart/x-mixed-replace;boundary="custom";charset=x"#]
        )!
        XCTAssertEqual(MJPEGLivePlayer.boundary(from: response), "custom")
    }

    func testMissingBoundaryFallsBackToFrigatesConstant() {
        let response = HTTPURLResponse(
            url: URL(string: "https://nvr.local/api/cam")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [:]
        )!
        XCTAssertEqual(MJPEGLivePlayer.boundary(from: response), "frame")
    }
}
