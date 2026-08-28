import Foundation
@testable import Frigate

/// A `SignalingChannel` that replays a scripted server side and records what was sent.
///
/// `URLSessionWebSocketTask` can't be intercepted by `MockURLProtocol` the way every other request
/// in this app can, which is the entire reason `SignalingChannel` exists. Frames pushed with
/// `receive(_:)` buffer in the underlying `AsyncStream`, so a test can script the whole exchange up
/// front and then drain it - no timing, no expectations, no flakiness.
actor FakeSignalingChannel: SignalingChannel {
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private(set) var sent: [String] = []
    private(set) var isClosed = false

    init() {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    // MARK: SignalingChannel

    func send(_ text: String) async throws {
        sent.append(text)
    }

    func messages() -> AsyncStream<String> {
        stream
    }

    func close() {
        isClosed = true
        continuation.finish()
    }

    // MARK: Test driving

    /// Push a frame as if the server had sent it.
    func receive(_ text: String) {
        continuation.yield(text)
    }

    /// End the inbound stream without marking the channel closed - the server hanging up on us.
    func finish() {
        continuation.finish()
    }
}
