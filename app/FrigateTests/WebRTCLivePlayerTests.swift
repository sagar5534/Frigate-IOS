import WebRTC
import XCTest
@testable import Frigate

@MainActor
final class WebRTCLivePlayerTests: XCTestCase {
    private var player: (any LivePlayer)?

    private func makeClient() -> FrigateClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return FrigateClient(baseURL: URL(string: "https://nvr.local:8971")!, session: URLSession(configuration: config))
    }

    /// Every test that starts a player must stop it: `start()` spawns a real connection attempt,
    /// and a player left running would outlive its test.
    override func tearDown() async throws {
        player?.stop()
        player = nil
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    // MARK: Factory

    /// Every tier of the ladder now has an implementation, and the player each rung builds must
    /// carry the transport it was asked for - that is what escalation reports and what the ladder
    /// walk in `LiveCameraModel` relies on.
    func testFactoryBuildsAPlayerForEveryTier() {
        let transports: [LiveTransport] = [
            .webrtc(streamName: "front_door_hi"),
            .mse(streamName: "front_door_hi"),
            .mjpeg(camera: "front_door", height: 720, fps: 5),
        ]
        for transport in transports {
            let built = LivePlayerFactory().makePlayer(for: transport, client: makeClient())
            XCTAssertEqual(built?.transport, transport)
            built?.stop()
        }
    }

    // MARK: Connection-state mapping
    //
    // The pure half of the player's state machine: the decisions that choose which failure the user
    // is shown. Getting these wrong is how someone ends up reconfiguring a router that was fine.

    func testConnectedWithFramesIsPlaying() {
        XCTAssertEqual(
            WebRTCLivePlayer.nextState(for: .connected, hasPlayed: false, hasVideoFrames: true),
            .playing
        )
    }

    /// Connected but silent is *not* "still connecting": the media path demonstrably works, so the
    /// camera is the suspect. Reporting `.connecting` here is what would let a deadline blame the
    /// network for a connection that had already succeeded.
    func testConnectedWithoutFramesIsStalledNotConnecting() {
        XCTAssertEqual(
            WebRTCLivePlayer.nextState(for: .connected, hasPlayed: false, hasVideoFrames: false),
            .stalled
        )
    }

    func testFailureBeforeAnyVideoIsAttributedToICE() {
        XCTAssertEqual(
            WebRTCLivePlayer.nextState(for: .failed, hasPlayed: false, hasVideoFrames: false),
            .failed(.iceFailed)
        )
    }

    func testFailureAfterVideoPlayedIsALostConnection() {
        XCTAssertEqual(
            WebRTCLivePlayer.nextState(for: .failed, hasPlayed: true, hasVideoFrames: true),
            .failed(.connectionLost)
        )
    }

    func testDisconnectIsStalledSoItCanRecoverOnItsOwn() {
        XCTAssertEqual(
            WebRTCLivePlayer.nextState(for: .disconnected, hasPlayed: true, hasVideoFrames: true),
            .stalled
        )
    }

    /// Transitions we either already reported or caused ourselves must not republish anything -
    /// `.closed` in particular is our own teardown.
    func testNewConnectingAndClosedProduceNoTransition() {
        for state: RTCPeerConnectionState in [.new, .connecting, .closed] {
            XCTAssertNil(
                WebRTCLivePlayer.nextState(for: state, hasPlayed: true, hasVideoFrames: true),
                "\(state.rawValue) should not change the reported state"
            )
        }
    }

    // MARK: Lifecycle

    func testNewPlayerIsIdleAndReportsItsTransport() {
        let player = WebRTCLivePlayer(streamName: "front_door_hi", client: makeClient())
        self.player = player

        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.transport, .webrtc(streamName: "front_door_hi"))
    }

    /// `LivePlayer.stop()` promises it is safe before `start()` and safe twice over. A teardown path
    /// that only works in the happy order is the kind of thing C5's scenePhase handling would trip
    /// over immediately.
    func testStopIsSafeBeforeStartAndWhenRepeated() {
        let player = WebRTCLivePlayer(streamName: "front_door_hi", client: makeClient())
        self.player = player

        player.stop()
        player.stop()
        XCTAssertEqual(player.state, .idle)
    }

    func testStartTransitionsToConnectingAndNotifies() {
        let player = WebRTCLivePlayer(streamName: "front_door_hi", client: makeClient())
        self.player = player

        var observed: [LivePlayerState] = []
        player.onStateChange = { observed.append($0) }
        player.start()

        XCTAssertEqual(player.state, .connecting)
        XCTAssertEqual(observed, [.connecting])
    }

    /// `start()` is documented idempotent: a second call must not open a second peer connection,
    /// and the only visible evidence of that from outside is that it publishes nothing.
    func testStartIsIdempotent() {
        let player = WebRTCLivePlayer(streamName: "front_door_hi", client: makeClient())
        self.player = player

        player.start()
        var observed: [LivePlayerState] = []
        player.onStateChange = { observed.append($0) }
        player.start()

        XCTAssertEqual(observed, [], "a second start() should be a no-op, not a re-announcement")
    }

    func testStopAfterStartReturnsToIdle() {
        let player = WebRTCLivePlayer(streamName: "front_door_hi", client: makeClient())
        self.player = player

        player.start()
        var observed: [LivePlayerState] = []
        player.onStateChange = { observed.append($0) }
        player.stop()

        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(observed, [.idle])
    }

    /// `@Observable` semantics aren't in play here - the player publishes through a callback - so
    /// the de-duplication has to be explicit, or a repeated state would re-notify every observer.
    func testRepeatedStateDoesNotRenotify() {
        let player = WebRTCLivePlayer(streamName: "front_door_hi", client: makeClient())
        self.player = player

        player.stop()
        var observed: [LivePlayerState] = []
        player.onStateChange = { observed.append($0) }
        player.stop()

        XCTAssertEqual(observed, [], "stopping an already-idle player should publish nothing")
    }
}
