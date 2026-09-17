import Foundation

/// A bidirectional text channel for go2rtc signaling.
///
/// This protocol exists for testability: `URLSessionWebSocketTask` cannot be intercepted by
/// `MockURLProtocol` the way every other request in this app can, so the test double has to sit one
/// layer higher. `LiveSocket` is the real conformer; C2's signaling tests drive a scripted
/// in-memory double instead of a server.
protocol SignalingChannel: Actor {
    func send(_ text: String) async throws
    /// Received text frames, in order. Finishes when the channel closes or fails - a transport
    /// error is reported as "no more messages", because that is the only thing a caller can act on.
    /// Single-consumer: iterate it once.
    func messages() -> AsyncStream<String>
    func close()
}

/// The MSE tier's view of the same socket: outbound is still JSON text (the `mse` codec
/// handshake), but inbound carries the media itself as binary fMP4 frames, so the stream has to
/// keep the text/binary distinction `SignalingChannel` deliberately flattens away.
///
/// Exists for the same reason as `SignalingChannel`: `URLSessionWebSocketTask` can't be mocked, so
/// the MSE handshake and demux pipeline are tested against a scripted conformer.
protocol MediaChannel: Actor {
    func send(_ text: String) async throws
    /// Received frames, in order, text and binary interleaved as they arrived. Finishes when the
    /// channel closes or fails. Single-consumer: iterate it once.
    func frames() -> AsyncStream<LiveSocketFrame>
    func close()
}
