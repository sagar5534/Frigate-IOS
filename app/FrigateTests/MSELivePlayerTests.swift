import XCTest
@testable import Frigate

@MainActor
final class MSELivePlayerTests: XCTestCase {
    private var player: MSELivePlayer?
    private var channel: FakeMediaChannel!

    override func setUp() {
        super.setUp()
        channel = FakeMediaChannel()
    }

    override func tearDown() async throws {
        player?.stop()
        player = nil
        channel = nil
        try await super.tearDown()
    }

    private func makeClient() -> FrigateClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return FrigateClient(baseURL: URL(string: "https://nvr.local:8971")!, session: URLSession(configuration: config))
    }

    private func makePlayer(handshakeDeadline: Duration = .seconds(10)) -> MSELivePlayer {
        let channel = channel!
        let player = MSELivePlayer(
            streamName: "front_door_hi",
            client: makeClient(),
            makeChannel: { _, _ in channel },
            handshakeDeadline: handshakeDeadline
        )
        self.player = player
        return player
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

    // MARK: Handshake wire format

    func testHandshakeRequestIsTheMSEEnvelopeWithVideoCodecs() throws {
        struct Envelope: Decodable { let type: String; let value: String }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(MSELivePlayer.handshakeRequest().utf8))

        XCTAssertEqual(envelope.type, "mse")
        XCTAssertTrue(envelope.value.contains("avc1"), "must offer H.264")
        XCTAssertTrue(envelope.value.contains("hvc1"), "must offer H.265")
        XCTAssertFalse(envelope.value.contains("mp4a"), "audio is out of scope and must not be requested")
    }

    func testHandshakeAckDecodingAcceptsMSEAndRejectsOtherTypes() {
        XCTAssertEqual(
            MSELivePlayer.decodeHandshakeAck(#"{"type":"mse","value":"video/mp4; codecs=\"avc1.64001f\""}"#),
            #"video/mp4; codecs="avc1.64001f""#
        )
        XCTAssertNil(MSELivePlayer.decodeHandshakeAck(#"{"type":"webrtc/answer","value":"sdp"}"#))
        XCTAssertNil(MSELivePlayer.decodeHandshakeAck("not json"))
    }

    // MARK: Lifecycle contract

    func testNewPlayerIsIdleAndReportsItsTransport() {
        let player = makePlayer()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.transport, .mse(streamName: "front_door_hi"))
    }

    func testStopIsSafeBeforeStartAndWhenRepeated() {
        let player = makePlayer()
        player.stop()
        player.stop()
        XCTAssertEqual(player.state, .idle)
    }

    func testStartTransitionsToConnectingAndSendsTheHandshake() async {
        let player = makePlayer()
        player.start()

        XCTAssertEqual(player.state, .connecting)
        await waitUntilSent()
        let sent = await channel.sent
        XCTAssertEqual(sent.count, 1)
        // Compare decoded, not as strings: JSONEncoder does not promise key order.
        XCTAssertEqual(sent.first.flatMap(MSELivePlayer.decodeHandshakeAck), "avc1.640029,avc1.64002A,avc1.640033,hvc1.1.6.L153.B0")
    }

    private func waitUntilSent(file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await !channel.sent.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("timed out waiting for the handshake send", file: file, line: line)
    }

    // MARK: Media flow

    func testInitSegmentAndSamplesReachPlayingWithTheStreamSize() async {
        let player = makePlayer()
        var sizes: [CGSize] = []
        player.onVideoSizeChange = { sizes.append($0) }
        player.start()
        await waitUntilSent()

        await channel.push(.text(#"{"type":"mse","value":"video/mp4; codecs=\"avc1.64001f\""}"#))
        await channel.push(.data(Data(FMP4Fixture.initSegment())))
        let sample = FMP4Fixture.SampleSpec(bytes: [0x00, 0x00, 0x00, 0x01, 0x65], isSync: true)
        await channel.push(.data(Data(FMP4Fixture.fragment(baseDecodeTime: 0, samples: [sample]))))

        await waitUntil("the player to reach .playing") { self.player?.state == .playing }
        XCTAssertEqual(player.videoSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(sizes, [CGSize(width: 1280, height: 720)])
    }

    func testGarbageMediaFailsAsDecodeFailedNotAsANetworkError() async {
        let player = makePlayer()
        player.start()
        await waitUntilSent()

        // A complete 8-byte header claiming a 3-byte box: structurally impossible ISO-BMFF.
        await channel.push(.data(Data([0x00, 0x00, 0x00, 0x03, 0x6D, 0x6F, 0x6F, 0x66])))

        await waitUntil("the demux failure to surface") { player.state == .failed(.decodeFailed) }
    }

    func testChannelEndingBeforeMediaIsASignalingFailure() async {
        let player = makePlayer()
        player.start()
        await waitUntilSent()

        await channel.finish()

        await waitUntil("the hangup to surface") { player.state == .failed(.signalingFailed) }
    }

    func testChannelEndingAfterPlayingIsALostConnection() async {
        let player = makePlayer()
        player.start()
        await waitUntilSent()

        await channel.push(.data(Data(FMP4Fixture.initSegment())))
        let sample = FMP4Fixture.SampleSpec(bytes: [0x00, 0x00, 0x00, 0x01, 0x65], isSync: true)
        await channel.push(.data(Data(FMP4Fixture.fragment(baseDecodeTime: 0, samples: [sample]))))
        await waitUntil("playback to start") { player.state == .playing }

        await channel.finish()

        await waitUntil("the drop to surface") { player.state == .failed(.connectionLost) }
    }

    /// go2rtc leaving the socket open but sending nothing is a negotiation failure - without this
    /// deadline it would sit indistinguishable from a slow connect until the model's 12s timeout
    /// blamed the wrong thing.
    func testNoMediaAfterHandshakeFailsWithinTheDeadline() async {
        let player = makePlayer(handshakeDeadline: .milliseconds(30))
        player.start()
        await waitUntilSent()

        await waitUntil("the handshake deadline to fire") { player.state == .failed(.signalingFailed) }
    }

    func testStopClosesTheChannelAndReturnsToIdle() async {
        let player = makePlayer()
        player.start()
        await waitUntilSent()

        player.stop()
        XCTAssertEqual(player.state, .idle)
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await channel.closeCount >= 1 { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("stop() should close the media channel")
    }
}
