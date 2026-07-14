import XCTest
@testable import Frigate

/// Behavioural contract, exercised against both the in-memory double and the real Keychain store so
/// they stay interchangeable.
final class CredentialStoreTests: XCTestCase {
    private let account = "https://nvr.local:8971|admin"
    private let otherAccount = "https://cabin.local:8971|admin"

    // MARK: In-memory double (pure logic)

    func testInMemoryPasswordRoundTrips() throws {
        let store = InMemoryCredentialStore()
        try store.savePassword("hunter2", account: account)
        XCTAssertEqual(try store.password(account: account), "hunter2")
    }

    func testInMemoryPasswordOverwrite() throws {
        let store = InMemoryCredentialStore()
        try store.savePassword("first", account: account)
        try store.savePassword("second", account: account)
        XCTAssertEqual(try store.password(account: account), "second")
    }

    func testInMemoryAccountsAreIsolated() throws {
        let store = InMemoryCredentialStore()
        try store.savePassword("a", account: account)
        try store.savePassword("b", account: otherAccount)
        XCTAssertEqual(try store.password(account: account), "a")
        XCTAssertEqual(try store.password(account: otherAccount), "b")
    }

    func testInMemoryTokenSlotAndClear() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.token())
        try store.saveToken("jwt-123")
        XCTAssertEqual(try store.token(), "jwt-123")

        try store.savePassword("pw", account: account)
        try store.clear()
        XCTAssertNil(try store.token())
        XCTAssertNil(try store.password(account: account))
    }

    // MARK: Real Keychain (hosted in the app, uses its entitlement)

    /// Fresh service name per run so items never collide across runs; access group left at the
    /// store's default (the shared group granted by the host app's entitlement).
    private func keychainStore() -> KeychainCredentialStore {
        KeychainCredentialStore(service: "com.sagarp.Frigate.tests.\(UUID().uuidString)")
    }

    func testKeychainPasswordRoundTripAndClear() throws {
        let store = keychainStore()
        defer { try? store.clear() }

        XCTAssertNil(try store.password(account: account))
        try store.savePassword("hunter2", account: account)
        XCTAssertEqual(try store.password(account: account), "hunter2")

        try store.savePassword("changed", account: account)
        XCTAssertEqual(try store.password(account: account), "changed")

        try store.clear()
        XCTAssertNil(try store.password(account: account))
    }

    func testKeychainTokenMirrorSlot() throws {
        let store = keychainStore()
        defer { try? store.clear() }

        XCTAssertNil(try store.token())
        try store.saveToken("jwt-abc")
        XCTAssertEqual(try store.token(), "jwt-abc")
    }

    func testKeychainAccountsAreIsolated() throws {
        let store = keychainStore()
        defer { try? store.clear() }

        try store.savePassword("a", account: account)
        try store.savePassword("b", account: otherAccount)
        XCTAssertEqual(try store.password(account: account), "a")
        XCTAssertEqual(try store.password(account: otherAccount), "b")
    }
}
