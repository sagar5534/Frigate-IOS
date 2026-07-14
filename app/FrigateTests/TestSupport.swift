import Foundation
@testable import Frigate

/// Builds an `AppModel` backed by ephemeral stores so tests never touch the real Keychain or the
/// App-Group `UserDefaults` suite. Each call gets an isolated config suite.
@MainActor
func makeTestAppModel(session: URLSession) -> AppModel {
    AppModel(
        session: session,
        credentialStore: InMemoryCredentialStore(),
        configStore: ServerConfigStore(suiteName: "test.\(UUID().uuidString)")
    )
}

func mockProtocolSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}
