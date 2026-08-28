import XCTest
@testable import Frigate

final class WebRTCSignalingTests: XCTestCase {
    private func answerJSON(_ sdp: String) -> String {
        #"{"type": "webrtc/answer", "value": "\#(sdp)"}"#
    }

    private func candidateJSON(_ candidate: String) -> String {
        #"{"type": "webrtc/candidate", "value": "\#(candidate)"}"#
    }

    /// Drains every event. Safe because each test finishes the channel before collecting, so the
    /// stream terminates on its own rather than on a timeout.
    private func collect(_ signaling: WebRTCSignaling) async -> [SignalingMessage] {
        var events: [SignalingMessage] = []
        for await event in await signaling.events() {
            events.append(event)
        }
        return events
    }

    // MARK: Encoding

    func testOfferEncodesToGo2RTCEnvelope() async throws {
        let channel = FakeSignalingChannel()
        try await WebRTCSignaling(channel: channel).send(.offer(sdp: "v=0-offer"))

        let sent = await channel.sent
        XCTAssertEqual(sent.count, 1)
        let json = try JSONSerialization.jsonObject(with: Data(sent[0].utf8)) as? [String: String]
        XCTAssertEqual(json?["type"], "webrtc/offer")
        XCTAssertEqual(json?["value"], "v=0-offer")
    }

    func testCandidateEncodesToGo2RTCEnvelope() async throws {
        let channel = FakeSignalingChannel()
        try await WebRTCSignaling(channel: channel).send(.candidate("candidate:1 1 udp 2 10.0.0.5 8555 typ host"))

        let sent = await channel.sent
        let json = try JSONSerialization.jsonObject(with: Data(sent[0].utf8)) as? [String: String]
        XCTAssertEqual(json?["type"], "webrtc/candidate")
        XCTAssertEqual(json?["value"], "candidate:1 1 udp 2 10.0.0.5 8555 typ host")
    }

    func testEncodedMessageRoundTripsThroughTheDecoder() throws {
        for message: SignalingMessage in [.offer(sdp: "v=0"), .answer(sdp: "v=0"), .candidate("candidate:1")] {
            XCTAssertEqual(SignalingMessage(json: try message.encoded()), message)
        }
    }

    // MARK: Decoding

    func testAnswerAndCandidateDecodeFromTheWire() async {
        let channel = FakeSignalingChannel()
        await channel.receive(answerJSON("v=0-answer"))
        await channel.receive(candidateJSON("candidate:1"))
        await channel.finish()

        let events = await collect(WebRTCSignaling(channel: channel))
        XCTAssertEqual(events, [.answer(sdp: "v=0-answer"), .candidate("candidate:1")])
    }

    /// The same go2rtc socket API also carries MSE's handshake (P4.1), so an unknown `type` is a
    /// normal thing to see. Neither it nor malformed JSON may end the connection - the answer that
    /// follows must still arrive.
    func testUnknownTypesAndMalformedFramesAreDroppedWithoutEndingTheStream() async {
        let channel = FakeSignalingChannel()
        await channel.receive(#"{"type": "mse", "value": "avc1.640029"}"#)
        await channel.receive("not json at all")
        await channel.receive(#"{"unexpected": "shape"}"#)
        await channel.receive(answerJSON("v=0-answer"))
        await channel.finish()

        let events = await collect(WebRTCSignaling(channel: channel))
        XCTAssertEqual(events, [.answer(sdp: "v=0-answer")])
    }

    /// go2rtc answers our offer and never sends one, so an inbound offer is something a consumer
    /// has no way to apply.
    func testInboundOfferIsIgnored() async {
        let channel = FakeSignalingChannel()
        await channel.receive(#"{"type": "webrtc/offer", "value": "v=0-offer"}"#)
        await channel.receive(answerJSON("v=0-answer"))
        await channel.finish()

        let events = await collect(WebRTCSignaling(channel: channel))
        XCTAssertEqual(events, [.answer(sdp: "v=0-answer")])
    }

    // MARK: Ordering

    /// The race this whole type exists to absorb: go2rtc trickles candidates as soon as it has
    /// them, and `RTCPeerConnection.add(_:)` rejects any that arrive before `setRemoteDescription`.
    func testCandidatesArrivingBeforeTheAnswerAreHeldBackAndReleasedInArrivalOrder() async {
        let channel = FakeSignalingChannel()
        await channel.receive(candidateJSON("candidate:early-1"))
        await channel.receive(candidateJSON("candidate:early-2"))
        await channel.receive(answerJSON("v=0-answer"))
        await channel.receive(candidateJSON("candidate:late-1"))
        await channel.finish()

        let events = await collect(WebRTCSignaling(channel: channel))
        XCTAssertEqual(events, [
            .answer(sdp: "v=0-answer"),
            .candidate("candidate:early-1"),
            .candidate("candidate:early-2"),
            .candidate("candidate:late-1"),
        ])
    }

    func testCandidatesAfterTheAnswerPassStraightThrough() async {
        let channel = FakeSignalingChannel()
        await channel.receive(answerJSON("v=0-answer"))
        await channel.receive(candidateJSON("candidate:1"))
        await channel.receive(candidateJSON("candidate:2"))
        await channel.finish()

        let events = await collect(WebRTCSignaling(channel: channel))
        XCTAssertEqual(events, [
            .answer(sdp: "v=0-answer"),
            .candidate("candidate:1"),
            .candidate("candidate:2"),
        ])
    }

    /// The server hanging up mid-handshake: candidates that never got an answer have nothing to be
    /// applied to, so they are dropped and the stream ends rather than hanging.
    func testChannelClosingBeforeAnAnswerYieldsNothingAndTerminates() async {
        let channel = FakeSignalingChannel()
        await channel.receive(candidateJSON("candidate:orphan"))
        await channel.finish()

        let events = await collect(WebRTCSignaling(channel: channel))
        XCTAssertEqual(events, [])
    }
}
