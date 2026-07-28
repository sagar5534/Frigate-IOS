import XCTest
@testable import Frigate

final class FrigateConfigTests: XCTestCase {
    private func decode(camerasJSON: String) throws -> FrigateConfig {
        let json = Data("""
        {
          "auth": {"enabled": true, "cookie_name": "frigate_token",
                   "session_length": 86400, "refresh_time": 1800},
          "cameras": \(camerasJSON)
        }
        """.utf8)
        return try JSONDecoder().decode(FrigateConfig.self, from: json)
    }

    func testCameraDefaultsToEnabledWhenFieldMissing() throws {
        let config = try decode(camerasJSON: #"{"front_door": {}}"#)
        XCTAssertEqual(config.cameras["front_door"]?.enabled, true)
    }

    func testCameraRespectsExplicitEnabledFlag() throws {
        let config = try decode(camerasJSON: #"{"front_door": {"enabled": true}, "attic": {"enabled": false}}"#)
        XCTAssertEqual(config.cameras["front_door"]?.enabled, true)
        XCTAssertEqual(config.cameras["attic"]?.enabled, false)
    }

    func testEnabledCameraNamesExcludesDisabledAndSortsResults() throws {
        let config = try decode(
            camerasJSON: #"{"porch": {"enabled": true}, "attic": {"enabled": false}, "front_door": {"enabled": true}}"#
        )
        XCTAssertEqual(config.enabledCameraNames, ["front_door", "porch"])
    }
}
