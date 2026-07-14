import Foundation

/// Protocol seam over secret storage so the logic that depends on it stays testable off-device
/// (an in-memory double stands in for the Keychain). `KeychainCredentialStore` is the real
/// conformer; C5 (`KeychainCredentialProvider`) and C6 (auto-connect) consume this.
///
/// Passwords are keyed by `account` (`<baseURL>|<username>`) so multiple servers can coexist; the
/// token is a single "current" mirror slot the Notification Service Extension reads later.
nonisolated protocol CredentialStoring: Sendable {
    func savePassword(_ password: String, account: String) throws
    func password(account: String) throws -> String?
    func saveToken(_ token: String) async throws
    func token() throws -> String?
    func clear() throws
}

/// The single source of truth for the password account key, so every layer (C4 store, C5 provider,
/// C6 persistence) agrees on the format.
nonisolated enum CredentialAccount {
    static func key(baseURL: URL, username: String) -> String {
        "\(baseURL.absoluteString)|\(username)"
    }
}
