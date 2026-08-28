import Foundation

/// A WebSocket for go2rtc signaling, built by `FrigateClient.liveSocket(for:)`.
///
/// An `actor` for two reasons: the non-`Sendable` `URLSessionWebSocketTask` never has to cross an
/// isolation boundary, and the receive loop's bookkeeping stays serialized against `close()`.
actor LiveSocket: SignalingChannel {
    private let task: URLSessionWebSocketTask
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private var pump: Task<Void, Never>?
    private var closed = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    /// Opens the connection and begins delivering frames to `messages()`. Idempotent; a no-op once
    /// closed, so a late `start()` can't resurrect a torn-down socket.
    func start() {
        guard pump == nil, !closed else { return }
        task.resume()
        pump = Task { [weak self] in await self?.receiveFrames() }
    }

    func messages() -> AsyncStream<String> {
        stream
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func close() {
        guard !closed else { return }
        closed = true
        pump?.cancel()
        pump = nil
        task.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    private func receiveFrames() async {
        while !closed {
            do {
                switch try await task.receive() {
                case .string(let text):
                    continuation.yield(text)
                case .data(let data):
                    // go2rtc's *signaling* channel is text-only. A binary frame here would be the
                    // MSE protocol's shape (P4.1) on the wrong socket, so decode it if it happens
                    // to be UTF-8 and otherwise drop it rather than tearing the connection down.
                    if let text = String(data: data, encoding: .utf8) {
                        continuation.yield(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                break
            }
        }
        continuation.finish()
    }

    deinit {
        continuation.finish()
        task.cancel(with: .goingAway, reason: nil)
    }
}
