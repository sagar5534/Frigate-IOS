import Foundation
import OSLog

/// Diagnostics for the live pipeline.
///
/// Live video fails in places nothing else in this app does - an ICE negotiation that ends with no
/// usable candidate pair leaves no HTTP status, no error body, nothing a user could report. The
/// trail of "socket opened / offer sent / answer received / N candidates / state X" is the only way
/// to tell "the server never answered" apart from "the server answered and the media path is
/// blocked", and those have completely different fixes.
nonisolated enum LiveLog {
    static let logger = Logger(subsystem: "com.sagarp.Frigate", category: "live")
}
