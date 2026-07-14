import Foundation

/// Concrete `CredentialProviding` (the seam defined in C1) backed by the shared credential store.
/// On a `401` the client calls `reauthenticate`, which re-runs `/api/login` with the stored
/// password. If no password is stored, it throws `.unauthorized` so the client surfaces it and the
/// app routes back to Login.
nonisolated struct KeychainCredentialProvider: CredentialProviding {
    let store: CredentialStoring
    let username: String
    let account: String

    init(store: CredentialStoring, baseURL: URL, username: String) {
        self.store = store
        self.username = username
        self.account = CredentialAccount.key(baseURL: baseURL, username: username)
    }

    func reauthenticate(_ client: FrigateClient) async throws {
        guard let password = try store.password(account: account), !password.isEmpty else {
            throw APIError.unauthorized
        }
        try await client.login(user: username, password: password)
    }
}
