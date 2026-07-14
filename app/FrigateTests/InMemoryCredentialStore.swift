import Foundation
@testable import Frigate

/// Test double standing in for the Keychain so credential-consuming logic (C5/C6) can be tested
/// off-device. Using a class with a lock instead of an actor to match the synchronous
/// protocol requirements while maintaining thread-safety.
final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var passwords: [String: String] = [:]
    private var currentToken: String?
    private let lock = NSLock()

    func savePassword(_ password: String, account: String) throws {
        lock.withLock {
            passwords[account] = password
        }
    }

    func password(account: String) throws -> String? {
        lock.withLock {
            passwords[account]
        }
    }

    func saveToken(_ token: String) async throws {
        lock.withLock {
            currentToken = token
        }
    }

    func token() throws -> String? {
        lock.withLock {
            currentToken
        }
    }

    func clear() throws {
        lock.withLock {
            passwords.removeAll()
            currentToken = nil
        }
    }
}
