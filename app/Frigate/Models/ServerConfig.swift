import Foundation

/// The non-secret record of the connected server, persisted so the app can auto-connect on
/// relaunch. The password lives separately in the Keychain (`CredentialStoring`); `username` is nil
/// when the server has auth disabled.
struct ServerConfig: Codable, Equatable, Sendable {
    let baseURL: URL
    let allowInsecure: Bool
    let username: String?
}
