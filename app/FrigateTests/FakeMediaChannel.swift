import Foundation
@testable import Frigate

/// A scripted `MediaChannel`, so the MSE player's handshake and demux pipeline run against frames
/// the test controls - the binary sibling of `FakeSignalingChannel`.
actor FakeMediaChannel: MediaChannel {
    private(set) var sent: [String] = []
    private(set) var closeCount = 0
    private let stream: AsyncStream<LiveSocketFrame>
    private let continuation: AsyncStream<LiveSocketFrame>.Continuation

    init() {
        (stream, continuation) = AsyncStream<LiveSocketFrame>.makeStream()
    }

    func send(_ text: String) async throws {
        sent.append(text)
    }

    func frames() -> AsyncStream<LiveSocketFrame> {
        stream
    }

    func close() {
        closeCount += 1
        continuation.finish()
    }

    /// Delivers one frame as the server would have.
    func push(_ frame: LiveSocketFrame) {
        continuation.yield(frame)
    }

    /// Ends the stream as a server hangup, without counting as a local close.
    func finish() {
        continuation.finish()
    }
}
