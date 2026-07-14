import Foundation

/// A `URLProtocol` that returns canned responses set per-test, so the client can be exercised
/// deterministically with no network.
final class MockURLProtocol: URLProtocol {
    /// Set per-test. Receives the outgoing request; returns the response + body, or throws to
    /// simulate a transport failure.
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Serves a fixed sequence of `(statusCode, body)` responses, one per request, for exercising
/// the 401 -> re-login -> retry path.
final class ResponseSequence: @unchecked Sendable {
    private var responses: [(Int, Data)]
    private let lock = NSLock()

    init(_ responses: [(Int, Data)]) {
        self.responses = responses
    }

    func next() -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !responses.isEmpty else { return (500, Data()) }
        return responses.removeFirst()
    }
}

/// Thread-safe call counter for handlers that must vary their response by attempt number.
final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
