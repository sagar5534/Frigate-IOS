import Foundation

/// Skips TLS validation for a server explicitly flagged insecure (self-signed cert). Constructed
/// from a per-server flag; when the flag is off, default handling applies and validation stands.
nonisolated final class InsecureTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    let allowInsecure: Bool

    init(allowInsecure: Bool) {
        self.allowInsecure = allowInsecure
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard allowInsecure,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
