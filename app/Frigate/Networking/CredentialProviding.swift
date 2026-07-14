import Foundation

/// The re-auth seam the client calls when a request comes back `401`. C1 ships no concrete
/// conformer (the retry path is proven with a test double); C5 supplies the Keychain-backed one.
nonisolated protocol CredentialProviding: Sendable {
    /// Perform a fresh login on `client` using stored credentials. Throws if none exist or login fails.
    func reauthenticate(_ client: FrigateClient) async throws
}
