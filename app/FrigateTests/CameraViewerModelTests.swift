import XCTest
@testable import Frigate

@MainActor
final class CameraViewerModelTests: XCTestCase {
    private let baseURL = URL(string: "https://nvr.local:8971")!

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeClient() -> FrigateClient {
        FrigateClient(baseURL: baseURL, session: mockProtocolSession())
    }

    private func makeConfig() throws -> FrigateConfig {
        try JSONDecoder().decode(FrigateConfig.self, from: Data(#"""
        {
          "auth": {"enabled": true, "cookie_name": "frigate_token", "session_length": 1, "refresh_time": 1},
          "cameras": {
            "front_door": {"live": {"streams": {"Main Stream": "front"}}},
            "back_yard": {"live": {"streams": {"Main Stream": "back"}}}
          },
          "go2rtc": {"streams": {"front": "rtsp://front", "back": "rtsp://back"}}
        }
        """#.utf8))
    }

    private func makeViewer(
        players: [String: FakeLivePlayer],
        initial: String = "front_door",
        snapshots: CameraGridModel? = nil
    ) throws -> CameraViewerModel {
        let client = makeClient()
        let config = try makeConfig()
        return CameraViewerModel(
            client: client,
            config: config,
            initialCameraName: initial,
            snapshots: snapshots ?? CameraGridModel(client: client, cameraNames: config.enabledCameraNames),
            makeLiveModel: { cameraName in
                LiveCameraModel(
                    client: client,
                    cameraName: cameraName,
                    config: config,
                    factory: LivePlayerFactory { _, _ in players[cameraName] }
                )
            }
        )
    }

    private func stubSnapshots() {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/jpeg"]
            )!
            return (response, Data([0xFF, 0xD8, 0xFF, 0xD9]))
        }
    }

    func testInitialSelectionAndFriendlyDisplayName() throws {
        let model = try makeViewer(players: ["front_door": FakeLivePlayer()])

        XCTAssertEqual(model.selectedCameraName, "front_door")
        XCTAssertEqual(model.displayName, "Front Door")
        XCTAssertEqual(model.cameraNames, ["back_yard", "front_door"])
        XCTAssertTrue(model.isMuted)
    }

    func testViewerReusesPrefetchedSnapshotsWithoutStartingAnotherRefreshLoop() async throws {
        stubSnapshots()
        let config = try makeConfig()
        let shared = CameraGridModel(client: makeClient(), cameraNames: config.enabledCameraNames)
        await shared.refreshAll()

        let viewer = try makeViewer(players: ["front_door": FakeLivePlayer()], snapshots: shared)
        viewer.appear()

        XCTAssertTrue(viewer.snapshots === shared)
        XCTAssertEqual(viewer.selectedSnapshot, shared.snapshots["front_door"])
        XCTAssertNotNil(viewer.selectedSnapshot.snapshot)
        XCTAssertFalse(shared.isAutoRefreshing, "the viewer must not start its own snapshot polling")
        viewer.disappear()
    }

    func testSharedSnapshotUpdatesReachTheSelectedCameraAfterSwitching() async throws {
        let bytes = LockedBox(Data([0xFF, 0xD8, 0x01, 0xD9]))
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, bytes.current)
        }
        let config = try makeConfig()
        let shared = CameraGridModel(client: makeClient(), cameraNames: config.enabledCameraNames)
        await shared.refreshAll()
        let viewer = try makeViewer(
            players: ["front_door": FakeLivePlayer(), "back_yard": FakeLivePlayer()],
            snapshots: shared
        )
        viewer.appear()
        viewer.select("back_yard")
        XCTAssertEqual(viewer.selectedSnapshot.snapshot?.data, bytes.current)

        let newerBytes = Data([0xFF, 0xD8, 0x02, 0xD9])
        bytes.current = newerBytes
        await shared.refreshAll()

        XCTAssertEqual(viewer.selectedSnapshot.snapshot?.data, newerBytes)
        XCTAssertEqual(shared.snapshots["back_yard"]?.snapshot?.data, newerBytes)
        viewer.disappear()
    }

    func testViewerLifecycleDoesNotStopTheSharedRefreshLoop() throws {
        stubSnapshots()
        let config = try makeConfig()
        let shared = CameraGridModel(client: makeClient(), cameraNames: config.enabledCameraNames)
        let viewer = try makeViewer(players: ["front_door": FakeLivePlayer()], snapshots: shared)

        shared.startAutoRefresh(interval: .seconds(3_600))
        XCTAssertTrue(shared.isAutoRefreshing)
        viewer.appear()
        viewer.sceneEnteredBackground()
        viewer.sceneBecameActive()
        viewer.disappear()

        XCTAssertTrue(shared.isAutoRefreshing, "only the list owns the shared refresh lifecycle")
        shared.stopAutoRefresh()
    }

    func testSwitchStopsOldPlayerBeforeStartingNewPlayer() throws {
        stubSnapshots()
        let front = FakeLivePlayer()
        let back = FakeLivePlayer()
        let model = try makeViewer(players: ["front_door": front, "back_yard": back])

        model.appear()
        XCTAssertEqual(front.startCount, 1)

        model.select("back_yard")

        XCTAssertEqual(front.stopCount, 1)
        XCTAssertEqual(back.startCount, 1)
        XCTAssertEqual(model.selectedCameraName, "back_yard")
        model.disappear()
    }

    func testSelectingCurrentCameraDoesNotReconnect() throws {
        stubSnapshots()
        let front = FakeLivePlayer()
        let model = try makeViewer(players: ["front_door": front])
        model.appear()

        model.select("front_door")

        XCTAssertEqual(front.startCount, 1)
        XCTAssertEqual(front.stopCount, 0)
        model.disappear()
    }

    func testMutePreferencePersistsAcrossCameraSwitch() throws {
        stubSnapshots()
        let front = FakeLivePlayer()
        let back = FakeLivePlayer()
        let model = try makeViewer(players: ["front_door": front, "back_yard": back])
        model.appear()

        model.toggleMuted()
        model.select("back_yard")

        XCTAssertFalse(model.isMuted)
        XCTAssertFalse(front.isMuted)
        XCTAssertFalse(back.isMuted)
        model.disappear()
    }

    func testBackgroundStopsAndActiveRestartsTheSelectedCamera() throws {
        stubSnapshots()
        let front = FakeLivePlayer()
        let model = try makeViewer(players: ["front_door": front])
        model.appear()

        model.sceneEnteredBackground()
        XCTAssertEqual(front.stopCount, 1)

        model.sceneBecameActive()
        XCTAssertEqual(front.startCount, 2)
        model.disappear()
    }
}
