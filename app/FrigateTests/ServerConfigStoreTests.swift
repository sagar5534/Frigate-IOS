import XCTest
@testable import Frigate

final class ServerConfigStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: ServerConfigStore!

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ServerConfigStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testLoadReturnsNilWhenEmpty() {
        XCTAssertNil(store.load())
    }

    func testSaveLoadRoundTrip() {
        let config = ServerConfig(
            baseURL: URL(string: "https://nvr.local:8971")!,
            allowInsecure: true,
            username: "admin"
        )
        store.save(config)
        XCTAssertEqual(store.load(), config)
    }

    func testSaveNilUsername() {
        let config = ServerConfig(
            baseURL: URL(string: "http://nvr.local:5000")!,
            allowInsecure: false,
            username: nil
        )
        store.save(config)
        XCTAssertEqual(store.load(), config)
    }

    func testClear() {
        store.save(ServerConfig(baseURL: URL(string: "https://nvr.local")!, allowInsecure: false, username: "a"))
        store.clear()
        XCTAssertNil(store.load())
    }
}
