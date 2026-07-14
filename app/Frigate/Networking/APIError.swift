import Foundation

/// The single error type every networking call maps into, so UI can exhaustively switch on it.
nonisolated enum APIError: Error, Equatable, Sendable {
    case invalidURL
    case transport(URLError)
    case unauthorized
    case authDisabled
    case http(status: Int, body: Data)
    case decoding(String)
    case notConnected
}
