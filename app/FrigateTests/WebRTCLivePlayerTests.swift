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
        try await super.tearDown()
    }

    // MARK: Factory

    func testFactoryBuildsAWebRTCPlayerForARestreamedLadder() {
        let ladder: [LiveTransport] = [
            .webrtc(streamName: "front_door_hi"),
            .mse(streamName: "front_door_hi"),
            .mjpeg(camera: "front_door"),
        ]
        let built = LivePlayerFactory().makePlayer(for: ladder, client: makeClient())
        player = built

        XCTAssertEqual(built?.transport, .webrtc(streamName: "front_door_hi"))
    }

    /// The tiers that don't exist yet are not errors - the caller keeps the P2 snapshot and reports
    /// live unavailable. This test flips to a real player when P4.1 or P4.2 lands, which is exactly
    /// the signal wanted at that point.
    func testFactoryReturnsNilForTiersNotBuiltYet() {
        let ladder: [LiveTransport] = [.mse(streamName: "front_door_hi"), .mjpeg(camera: "front_door")]
        XCTAssertNil(LivePlayerFactory().makePlayer(for: ladder, client: makeClient()))
    }

    func testFactoryReturnsNilForAnEmptyLadder() {
        XCTAssertNil(LivePlayerFactory().makePlayer(for: [], client: makeClient()))
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
