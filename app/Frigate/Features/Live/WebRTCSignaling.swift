import Foundation

/// One message on go2rtc's WebRTC signaling channel.
///
/// The wire format is a flat `{"type": …, "value": …}` envelope. go2rtc namespaces the WebRTC types
/// under `webrtc/` because the same socket API also carries MSE's `mse` handshake (P4.1) - which is
/// why an unrecognised `type` is a normal thing to see rather than a protocol violation.
nonisolated enum SignalingMessage: Equatable, Sendable {
    /// Our SDP offer. go2rtc only ever answers; it never offers.
    case offer(sdp: String)
    case answer(sdp: String)
    /// A single ICE candidate, in SDP attribute form (`candidate:…`).
    case candidate(String)
}

extension SignalingMessage {
    private struct Envelope: Codable {
        let type: String
        let value: String
    }

    private static let offerType = "webrtc/offer"
    private static let answerType = "webrtc/answer"
    private static let candidateType = "webrtc/candidate"

    /// `nil` for anything we don't handle - an unknown `type`, or a frame that isn't the envelope
    /// shape at all. Dropping those is deliberate and matches Frigate's PWA: an unrecognised
    /// message is not a reason to tear down a working connection.
    init?(json: String) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)) else {
            return nil
        }
        switch envelope.type {
        case Self.offerType: self = .offer(sdp: envelope.value)
        case Self.answerType: self = .answer(sdp: envelope.value)
        case Self.candidateType: self = .candidate(envelope.value)
        default: return nil
        }
    }

    func encoded() throws -> String {
        let envelope: Envelope = switch self {
        case .offer(let sdp): Envelope(type: Self.offerType, value: sdp)
        case .answer(let sdp): Envelope(type: Self.answerType, value: sdp)
        case .candidate(let candidate): Envelope(type: Self.candidateType, value: candidate)
        }
        return String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
    }
}

/// Drives go2rtc's WebRTC signaling handshake over a `SignalingChannel`.
///
/// It owns the *protocol* and nothing about the media: message shapes and ordering rules, with no
/// reference to `RTCPeerConnection`. That split is what lets the handshake be tested against a
/// scripted channel with no server and no libwebrtc binary, and it keeps C3's player down to
/// "create offer, apply answer, add candidates".
nonisolated struct WebRTCSignaling: Sendable {
    private let channel: any SignalingChannel

    init(channel: any SignalingChannel) {
        self.channel = channel
    }

    func send(_ message: SignalingMessage) async throws {
        try await channel.send(message.encoded())
    }

    /// Inbound signaling, reordered so each event can be applied to a peer connection the moment
    /// it arrives.
    ///
    /// go2rtc trickles candidates as soon as it has them, so they routinely beat the answer down
    /// the wire. `RTCPeerConnection.add(_:)` rejects a candidate that arrives before
    /// `setRemoteDescription`, so candidates seen before the answer are held here and released
    /// immediately after it, in arrival order. Keeping that race in the protocol layer is what
    /// makes it testable at all - in the player it would need a live server to reproduce.
    ///
    /// The stream finishes when the channel does. Single-consumer: iterate it once.
    func events() async -> AsyncStream<SignalingMessage> {
        let inbound = await channel.messages()
        let (stream, continuation) = AsyncStream<SignalingMessage>.makeStream()

        let pump = Task {
            var pendingCandidates: [SignalingMessage] = []
            var answered = false

            for await text in inbound {
                guard let message = SignalingMessage(json: text) else { continue }
                switch message {
                case .answer:
                    answered = true
                    continuation.yield(message)
                    for candidate in pendingCandidates {
                        continuation.yield(candidate)
                    }
                    pendingCandidates.removeAll()
                case .candidate:
                    if answered {
                        continuation.yield(message)
                    } else {
                        pendingCandidates.append(message)
                    }
                case .offer:
                    // go2rtc answers our offer and never sends one of its own. Ignore rather than
                    // hand a consumer an event it has no way to apply.
                    continue
                }
            }
            // Candidates still pending here never got an answer, so the negotiation failed and
            // there is nothing to apply them to. Dropping them is the whole story.
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }

        return stream
    }
}
