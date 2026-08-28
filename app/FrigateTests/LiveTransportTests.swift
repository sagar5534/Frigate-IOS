import XCTest
@testable import Frigate

final class LiveTransportTests: XCTestCase {
    private func config(cameras: String, go2rtcStreams: String) throws -> FrigateConfig {
        let json = Data("""
        {
          "auth": {"enabled": true, "cookie_name": "frigate_token",
                   "session_length": 86400, "refresh_time": 1800},
          "cameras": \(cameras),
          "go2rtc": {"streams": \(go2rtcStreams)}
        }
        """.utf8)
        return try JSONDecoder().decode(FrigateConfig.self, from: json)
    }

    func testRestreamedCameraGetsFullLadderHeadedByWebRTC() throws {
        let config = try config(
            cameras: #"{"front_door": {"live": {"streams": {"Main": "front_door_hi"}}}}"#,
            go2rtcStreams: #"{"front_door_hi": "rtsp://cam/live"}"#
        )
        XCTAssertEqual(
            LiveStreamSource.ladder(camera: "front_door", config: config),
            [.webrtc(streamName: "front_door_hi"), .mse(streamName: "front_door_hi"), .mjpeg(camera: "front_door")]
        )
    }

    /// The go2rtc stream name is not the camera name here, which is exactly the case a naive
    /// implementation gets wrong: `src=` must carry the stream, `mjpeg` must carry the camera.
    func testLadderCarriesStreamNameForWebRTCAndCameraNameForMJPEG() throws {
        let config = try config(
            cameras: #"{"driveway": {"live": {"streams": {"Main": "drive_main"}}}}"#,
            go2rtcStreams: #"{"drive_main": "rtsp://cam/live"}"#
        )
        let ladder = LiveStreamSource.ladder(camera: "driveway", config: config)
        XCTAssertEqual(ladder.first, .webrtc(streamName: "drive_main"))
        XCTAssertEqual(ladder.last, .mjpeg(camera: "driveway"))
    }

    func testUnrestreamedCameraFallsToMJPEGOnly() throws {
        let config = try config(
            cameras: #"{"attic": {"live": {"streams": {"Main": "attic"}}}}"#,
            go2rtcStreams: #"{"front_door": "rtsp://cam/live"}"#
        )
        XCTAssertEqual(LiveStreamSource.ladder(camera: "attic", config: config), [.mjpeg(camera: "attic")])
    }

    /// Frigate's own `verify_valid_live_stream_names` returns its ValueError instead of raising it,
    /// so a config naming a nonexistent restream reaches the client intact. With no valid
    /// candidate left, MJPEG is the honest answer.
    func testLiveStreamNamingNonexistentRestreamFallsToMJPEG() throws {
        let config = try config(
            cameras: #"{"front_door": {"live": {"streams": {"Main": "typo_stream"}}}}"#,
            go2rtcStreams: #"{"front_door": "rtsp://cam/live"}"#
        )
        XCTAssertEqual(LiveStreamSource.ladder(camera: "front_door", config: config), [.mjpeg(camera: "front_door")])
    }

    /// Older/partial payloads omit `live.streams` entirely; the server would have defaulted it to
    /// `{name: name}`, so the camera name itself is the right thing to test against go2rtc.
    func testCameraWithNoLiveStreamsFallsBackToItsOwnNameAsTheStream() throws {
        let config = try config(
            cameras: #"{"front_door": {}}"#,
            go2rtcStreams: #"{"front_door": "rtsp://cam/live"}"#
        )
        XCTAssertEqual(LiveStreamSource.ladder(camera: "front_door", config: config).first,
                       .webrtc(streamName: "front_door"))
    }

    /// The dominant multi-stream shape: a main stream named after the camera plus a sub stream.
    /// Matching the camera name is what keeps us agreeing with the PWA without needing the JSON
    /// key order that `JSONDecoder` throws away. Labels are ordered so that a naive
    /// alphabetically-first pick would choose the *sub* stream and fail here.
    func testMultiStreamCameraPrefersTheStreamNamedAfterTheCamera() throws {
        let config = try config(
            cameras: """
            {"front_door": {"live": {"streams": {
              "alpha_sub": "front_door_sub",
              "zebra_main": "front_door"
            }}}}
            """,
            go2rtcStreams: #"{"front_door": "rtsp://cam/hi", "front_door_sub": "rtsp://cam/lo"}"#
        )
        XCTAssertEqual(LiveStreamSource.ladder(camera: "front_door", config: config).first,
                       .webrtc(streamName: "front_door"))
    }

    /// No stream carries the camera's name, so there is nothing meaningful to prefer. The
    /// requirement that survives is *stability*: the same config must resolve to the same stream on
    /// every launch, which hash-ordered JSON keys would not give us.
    func testMultiStreamCameraWithoutACameraNamedStreamResolvesDeterministically() throws {
        let cameras = """
        {"front_door": {"live": {"streams": {
          "zebra_main": "cam1_hi",
          "alpha_sub": "cam1_lo"
        }}}}
        """
        let streams = #"{"cam1_hi": "rtsp://cam/hi", "cam1_lo": "rtsp://cam/lo"}"#
        let first = LiveStreamSource.ladder(camera: "front_door", config: try config(cameras: cameras, go2rtcStreams: streams))
        let second = LiveStreamSource.ladder(camera: "front_door", config: try config(cameras: cameras, go2rtcStreams: streams))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first, .webrtc(streamName: "cam1_hi"))
    }

    /// One valid stream alongside a typo'd one still gives a working live view - the typo is
    /// skipped rather than dragging the whole camera down to MJPEG.
    func testCandidatesSkipStreamsThatDoNotExistInGo2RTC() throws {
        let config = try config(
            cameras: """
            {"front_door": {"live": {"streams": {
              "aaa_typo": "does_not_exist",
              "bbb_good": "front_door"
            }}}}
            """,
            go2rtcStreams: #"{"front_door": "rtsp://cam/hi"}"#
        )
        XCTAssertEqual(LiveStreamSource.ladder(camera: "front_door", config: config).first,
                       .webrtc(streamName: "front_door"))
    }

    func testUnknownCameraFallsToMJPEGRatherThanCrashing() throws {
        let config = try config(cameras: "{}", go2rtcStreams: #"{"front_door": "rtsp://cam/live"}"#)
        XCTAssertEqual(LiveStreamSource.ladder(camera: "ghost", config: config), [.mjpeg(camera: "ghost")])
    }
}
