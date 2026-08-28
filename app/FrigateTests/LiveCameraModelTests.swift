import XCTest
@testable import Frigate

@MainActor
final class LiveCameraModelTests: XCTestCase {
    /// Sub-millisecond timings so a backoff chain runs in real time without anyone sleeping.
    private var fastPolicy: LiveCameraModel.Policy {
        LiveCameraModel.Policy(
            startupDeadline: .milliseconds(20),
            stallDeadline: .milliseconds(20),
            initialBackoff: .milliseconds(1),
            maximumBackoff: .milliseconds(5),
            maximumAttempts: 3
        )
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeClient() -> FrigateClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return FrigateClient(baseURL: URL(string: "https://nvr.local:8971")!, session: URLSession(configuration: config))
    }

    private func makeConfig(restreamed: Bool = true) throws -> FrigateConfig {
        let go2rtc = restreamed ? #"{"streams": {"cam1": "rtsp://cam/live"}}"# : #"{"streams": {}}"#
        let json = Data("""
        {
          "auth": {"enabled": true, "cookie_name": "frigate_token", "session_length": 1, "refresh_time": 1},
          "cameras": {"front_door": {"live": {"streams": {"Main Stream": "cam1"}}}},
          "go2rtc": \(go2rtc)
        }
        """.utf8)
        return try JSONDecoder().decode(FrigateConfig.self, from: json)
    }

    /// Polls rather than sleeping a fixed amount: fast when the condition holds, and a clear
    /// failure rather than a flaky pass when it doesn't. See `LEARNINGS.md` on timer-loop tests.
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

    private func makeModel(
        config: FrigateConfig,
        player: FakeLivePlayer? = nil
    ) -> LiveCameraModel {
        let factory = player.map { player in
            LivePlayerFactory { transport, _ in
                if case .webrtc = transport { return player }
                return nil
            }
        } ?? LivePlayerFactory { _, _ in nil }

        return LiveCameraModel(
            client: makeClient(),
            cameraName: "front_door",
            config: config,
            factory: factory,
            policy: fastPolicy
        )
    }

    // MARK: Availability

    /// A camera with no playable tier is not an error state to shout about - the snapshot behind it
    /// is still a working camera view, and this is the expected result until P4.2 ships MJPEG.
    func testCameraWithNoImplementedTierReportsNotAvailableAndDoesNotRetry() async throws {
        let model = makeModel(config: try makeConfig(restreamed: false))
        model.start()

        XCTAssertEqual(model.state, .failed(.notAvailable))
        XCTAssertNil(model.player)
        XCTAssertTrue(model.isAwaitingManualRetry)
    }

    func testStartBuildsThePlayerForTheBestRung() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()

        XCTAssertEqual(player.startCount, 1)
        XCTAssertEqual(model.state, .connecting)
        model.stop()
    }

    func testStartIsIdempotentWhileAPlayerExists() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        model.start()

        XCTAssertEqual(player.startCount, 1)
        model.stop()
    }

    // MARK: Playing

    func testPlayingPropagatesAndIsWhatTheSnapshotPollWatches() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        player.simulate(.playing)

        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.state, .playing)
        model.stop()
    }

    /// The deadline exists because libwebrtc's own ICE timeout is tens of seconds. Reaching
    /// `.playing` has to disarm it, or a healthy stream would be torn down mid-view.
    func testReachingPlayingCancelsTheStartupDeadline() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        player.simulate(.playing)

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.state, .playing, "the startup deadline should have been cancelled")
        model.stop()
    }

    // MARK: Failure policy

    /// `.iceFailed` is structural - negotiation worked and no candidate pair connected, which means
    /// port 8555 is unreachable from this network. Retrying changes nothing but the battery.
    func testIceFailureIsNotRetriedAutomatically() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        let startsBefore = player.startCount
        player.simulate(.failed(.iceFailed))

        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(player.startCount, startsBefore, "ICE failure must not trigger a reconnect")
        XCTAssertTrue(model.isAwaitingManualRetry)
        model.stop()
    }

    func testLostConnectionIsRetriedAutomatically() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        player.simulate(.failed(.connectionLost))

        await waitUntil("the player to be restarted") { player.startCount >= 2 }
        model.stop()
    }

    func testSignalingFailureIsRetriedAutomatically() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        player.simulate(.failed(.signalingFailed))

        await waitUntil("the player to be restarted") { player.startCount >= 2 }
        model.stop()
    }

    /// Deadlines pushed far out of reach, so the *only* thing that can end a reconnect chain in
    /// these tests is the attempt budget. Without this the 20ms startup deadline can fire and
    /// produce `.failed(.iceFailed)`, which is also not auto-retried - so the test would go green
    /// for the wrong reason.
    private var budgetOnlyPolicy: LiveCameraModel.Policy {
        var policy = fastPolicy
        policy.startupDeadline = .seconds(60)
        policy.stallDeadline = .seconds(60)
        return policy
    }

    /// Drives failures until the model stops reconnecting, and reports how many starts happened.
    private func exhaustReconnectBudget(
        _ model: LiveCameraModel,
        _ player: FakeLivePlayer
    ) async {
        for _ in 0..<(fastPolicy.maximumAttempts + 3) {
            player.simulate(.failed(.connectionLost))
            let startsBefore = player.startCount
            // Either it reconnects (start count rises) or the budget is spent and it stops.
            for _ in 0..<400 where player.startCount == startsBefore && !model.isAwaitingManualRetry {
                try? await Task.sleep(for: .milliseconds(1))
            }
            if model.isAwaitingManualRetry { return }
        }
    }

    /// Retrying forever on a camera nobody is watching is just battery, so the chain has to stop
    /// and hand over to the user - after exactly the budgeted number of attempts, not fewer.
    func testReconnectGivesUpAfterExactlyTheAttemptLimit() async throws {
        let player = FakeLivePlayer()
        let model = LiveCameraModel(
            client: makeClient(),
            cameraName: "front_door",
            config: try makeConfig(),
            factory: LivePlayerFactory { _, _ in player },
            policy: budgetOnlyPolicy
        )
        model.start()
        await exhaustReconnectBudget(model, player)

        XCTAssertEqual(
            player.startCount, budgetOnlyPolicy.maximumAttempts + 1,
            "one initial start plus exactly the budgeted automatic attempts"
        )
        XCTAssertTrue(model.isAwaitingManualRetry)
        model.stop()
    }

    /// A person tapping Retry is new information, so the budget resets.
    func testManualRetryResetsTheAttemptBudget() async throws {
        let player = FakeLivePlayer()
        let model = LiveCameraModel(
            client: makeClient(),
            cameraName: "front_door",
            config: try makeConfig(),
            factory: LivePlayerFactory { _, _ in player },
            policy: budgetOnlyPolicy
        )
        model.start()
        await exhaustReconnectBudget(model, player)
        let startsWhenExhausted = player.startCount

        model.retry()
        XCTAssertEqual(player.startCount, startsWhenExhausted + 1, "retry starts the player again")

        // And the budget is genuinely reset, not merely nudged: a full second chain runs.
        await exhaustReconnectBudget(model, player)
        XCTAssertEqual(
            player.startCount,
            startsWhenExhausted + 1 + budgetOnlyPolicy.maximumAttempts,
            "a manual retry should restore the whole automatic budget"
        )
        model.stop()
    }

    /// A stream that played, dropped, reconnected and then went silent has demonstrably working
    /// networking, so the failure must not be reported as "the camera sent no video". This is the
    /// case where the reconnect path has to carry `hasEverPlayed` across its own teardown.
    func testHistoryOfPlayingSurvivesAnAutomaticReconnect() async throws {
        let player = FakeLivePlayer()
        var policy = fastPolicy
        policy.startupDeadline = .seconds(60)
        let model = LiveCameraModel(
            client: makeClient(),
            cameraName: "front_door",
            config: try makeConfig(),
            factory: LivePlayerFactory { _, _ in player },
            policy: policy
        )
        model.start()
        player.simulate(.playing)
        player.simulate(.failed(.connectionLost))
        await waitUntil("the reconnect to fire") { player.startCount >= 2 }

        player.simulate(.stalled)
        await waitUntil("the stall to resolve as a lost connection") {
            model.state == .failed(.connectionLost)
        }
        model.stop()
    }

    // MARK: Deadlines

    func testAConnectionThatNeverPlaysFailsWithIceFailedRatherThanSpinning() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()

        await waitUntil("the startup deadline to fire") { model.state == .failed(.iceFailed) }
        XCTAssertGreaterThanOrEqual(player.stopCount, 1, "the stuck player should have been torn down")
        model.stop()
    }

    /// A stall gets a grace period first: libwebrtc often recovers on its own, and a reconnect
    /// costs a fresh handshake and a second of black.
    func testAStallThatDoesNotRecoverBecomesALostConnection() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        player.simulate(.playing)
        player.simulate(.stalled)

        await waitUntil("the stall to escalate") { player.startCount >= 2 }
        model.stop()
    }

    func testAStallThatRecoversDoesNotReconnect() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        player.simulate(.playing)
        player.simulate(.stalled)
        player.simulate(.playing)

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(player.startCount, 1, "a recovered stall must not force a reconnect")
        XCTAssertEqual(model.state, .playing)
        model.stop()
    }

    /// The distinction that matters most in the failure copy: a stall *before* any video has
    /// arrived proves the network path works, so blaming it would send someone to reconfigure a
    /// router that is fine. `maximumAttempts: 0` pins the state so the assertion isn't racing the
    /// reconnect that would otherwise follow.
    func testAStallBeforeAnyVideoReportsNoVideoRatherThanANetworkFailure() async throws {
        let player = FakeLivePlayer()
        var policy = fastPolicy
        policy.maximumAttempts = 0
        let model = LiveCameraModel(
            client: makeClient(),
            cameraName: "front_door",
            config: try makeConfig(),
            factory: LivePlayerFactory { _, _ in player },
            policy: policy
        )
        model.start()
        player.simulate(.stalled)

        await waitUntil("the stall deadline to resolve") { model.state == .failed(.noVideo) }
    }

    /// The mirror image: video played, then stopped. Now the network really is the suspect.
    func testAStallAfterVideoPlayedReportsALostConnection() async throws {
        let player = FakeLivePlayer()
        var policy = fastPolicy
        policy.maximumAttempts = 0
        let model = LiveCameraModel(
            client: makeClient(),
            cameraName: "front_door",
            config: try makeConfig(),
            factory: LivePlayerFactory { _, _ in player },
            policy: policy
        )
        model.start()
        player.simulate(.playing)
        player.simulate(.stalled)

        await waitUntil("the stall deadline to resolve") { model.state == .failed(.connectionLost) }
    }

    func testVideoAspectRatioComesFromTheStreamNotAnAssumption() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()

        XCTAssertNil(model.videoAspectRatio, "unknown until the stream reports its size")
        player.videoSize = CGSize(width: 1600, height: 1200)
        XCTAssertEqual(model.videoAspectRatio ?? 0, 4.0 / 3.0, accuracy: 0.001)
        model.stop()
    }

    /// A camera that switches resolution mid-stream changes nothing else observable, so the size
    /// has to arrive as its own push rather than being noticed in passing during a state change.
    func testAMidStreamResolutionChangeUpdatesTheAspectRatio() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        player.simulate(.playing)
        player.videoSize = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(model.videoAspectRatio ?? 0, 16.0 / 9.0, accuracy: 0.001)

        player.videoSize = CGSize(width: 640, height: 480)
        XCTAssertEqual(model.videoAspectRatio ?? 0, 4.0 / 3.0, accuracy: 0.001)
        model.stop()
    }

    /// Drives the wording of the status badge: nothing can be "reconnecting" that never connected.
    func testHasEverPlayedIsFalseUntilVideoActuallyArrives() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        player.simulate(.stalled)
        XCTAssertFalse(model.hasEverPlayed, "a first connection that pauses has not played yet")

        player.simulate(.playing)
        XCTAssertTrue(model.hasEverPlayed)
        model.stop()
    }

    // MARK: Teardown

    func testStopTearsDownAndIsSafeToRepeat() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        model.stop()
        model.stop()

        XCTAssertNil(model.player)
        XCTAssertEqual(model.state, .idle)
        XCTAssertGreaterThanOrEqual(player.stopCount, 1)
    }

    /// Teardown must also disarm the policy. A pending reconnect that fires after the view is gone
    /// would resurrect a peer connection nobody is watching.
    func testStopCancelsAPendingReconnect() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        player.simulate(.failed(.connectionLost))
        model.stop()
        let startsAtStop = player.startCount

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(player.startCount, startsAtStop, "a stopped model must not reconnect")
        XCTAssertEqual(model.state, .idle)
    }

    func testStopCancelsAPendingStartupDeadline() async throws {
        let player = FakeLivePlayer()
        let model = makeModel(config: try makeConfig(), player: player)
        model.start()
        model.stop()

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.state, .idle, "a stopped model must not report a deadline failure")
    }
}
