import XCTest
@testable import Frigate

final class FrigateConfigTests: XCTestCase {
    private func decode(camerasJSON: String, go2rtcJSON: String? = nil) throws -> FrigateConfig {
        let go2rtc = go2rtcJSON.map { ",\n  \"go2rtc\": \($0)" } ?? ""
        let json = Data("""
        {
          "auth": {"enabled": true, "cookie_name": "frigate_token",
                   "session_length": 86400, "refresh_time": 1800},
          "cameras": \(camerasJSON)\(go2rtc)
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

    // MARK: go2rtc + live streams (P4)

    /// The P1/P2 fixtures know nothing about either field; they must keep decoding unchanged.
    func testPayloadWithoutGo2RTCOrLiveStreamsStillDecodes() throws {
        let config = try decode(camerasJSON: #"{"front_door": {}}"#)
        XCTAssertTrue(config.go2rtc.streamNames.isEmpty)
        XCTAssertEqual(config.cameras["front_door"]?.live.streams, [])
    }

    /// Real configs write a stream's source as either a bare URL or a list of them. We read only
    /// the keys, so both shapes have to decode without anyone modelling go2rtc's source syntax.
    func testGo2RTCStreamValuesDecodeWhetherStringOrArray() throws {
        let config = try decode(
            camerasJSON: #"{"front_door": {}}"#,
            go2rtcJSON: """
            {"streams": {
              "front_door": "rtsp://cam/live",
              "back_yard": ["rtsp://cam2/live", "ffmpeg:back_yard#audio=aac"]
            }}
            """
        )
        XCTAssertEqual(config.go2rtc.streamNames, ["front_door", "back_yard"])
    }

    func testGo2RTCWithNullOrMissingStreamsDecodesToEmpty() throws {
        XCTAssertTrue(try decode(camerasJSON: "{}", go2rtcJSON: #"{"streams": null}"#).go2rtc.streamNames.isEmpty)
        XCTAssertTrue(try decode(camerasJSON: "{}", go2rtcJSON: "{}").go2rtc.streamNames.isEmpty)
    }

    func testLiveStreamsMapLabelToGo2RTCStreamName() throws {
        let config = try decode(
            camerasJSON: #"{"front_door": {"live": {"streams": {"Main Stream": "front_door"}}}}"#
        )
        XCTAssertEqual(
            config.cameras["front_door"]?.live.streams,
            [FrigateConfig.LiveInfo.Stream(label: "Main Stream", name: "front_door")]
        )
    }

    /// `JSONDecoder`'s `allKeys` comes back in hash order - not document order, not sorted - and
    /// Swift's hasher is seeded per process, so the natural order is genuinely different from one
    /// launch to the next. Sorting is what makes this array deterministic at all. The document
    /// order here is deliberately neither sorted nor reverse-sorted, so a decoder that stopped
    /// sorting would fail this rather than pass by luck. See `docs/LEARNINGS.md`.
    func testLiveStreamsAreSortedByLabelBecauseJSONKeyOrderIsUnstable() throws {
        let config = try decode(
            camerasJSON: """
            {"front_door": {"live": {"streams": {
              "mike": "front_door_mid",
              "zebra": "front_door",
              "alpha": "front_door_sub"
            }}}}
            """
        )
        XCTAssertEqual(
            config.cameras["front_door"]?.live.streams.map(\.label),
            ["alpha", "mike", "zebra"]
        )
    }
}
