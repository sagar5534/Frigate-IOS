import Foundation

/// One WebSocket message. go2rtc's socket API is text for the JSON handshake envelopes and binary
/// for media (MSE's fMP4 segments); WebRTC signaling only ever sees `.text`.
nonisolated enum LiveSocketFrame: Sendable {
    case text(String)
    case data(Data)
}

/// A WebSocket for go2rtc's socket API, built by `FrigateClient.liveSocket(for:)`.
///
/// An `actor` for two reasons: the non-`Sendable` `URLSessionWebSocketTask` never has to cross an
/// isolation boundary, and the receive loop's bookkeeping stays serialized against `close()`.
///
/// One socket serves both live protocols: WebRTC signaling consumes it as a `SignalingChannel`
/// (text only), MSE as a `MediaChannel` (text + binary). The streams share one pump, so use one
/// view or the other - never both on the same socket.
actor LiveSocket: SignalingChannel, MediaChannel {
    private let task: URLSessionWebSocketTask
    private let stream: AsyncStream<LiveSocketFrame>
    private let continuation: AsyncStream<LiveSocketFrame>.Continuation
    private var pump: Task<Void, Never>?
    private var closed = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
        let (stream, continuation) = AsyncStream<LiveSocketFrame>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    /// Opens the connection and begins delivering frames. Idempotent; a no-op once closed, so a
    /// late `start()` can't resurrect a torn-down socket.
    func start() {
        guard pump == nil, !closed else { return }
        task.resume()
        pump = Task { [weak self] in await self?.receiveFrames() }
    }

    /// Every frame, in order. Single-consumer: iterate it once.
    func frames() -> AsyncStream<LiveSocketFrame> {
        stream
    }

    /// The text frames only - the `SignalingChannel` view of the socket. WebRTC signaling is
    /// text-only, and a stray binary frame there would be another protocol's traffic, dropped for
    /// the same reason unknown JSON types are.
    func messages() -> AsyncStream<String> {
        let frames = stream
        let (text, continuation) = AsyncStream<String>.makeStream()
        let pump = Task {
            for await frame in frames {
                if case .text(let string) = frame {
                    continuation.yield(string)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }
        return text
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
                    continuation.yield(.text(text))
                case .data(let data):
                    continuation.yield(.data(data))
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
