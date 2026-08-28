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
