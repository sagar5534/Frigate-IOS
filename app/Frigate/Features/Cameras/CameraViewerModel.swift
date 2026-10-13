import Foundation
import Observation

/// Owns the single-page camera viewer: one selected live player plus snapshot thumbnails for every
/// camera. Switching is deliberately synchronous at the lifecycle boundary, so the old player is
/// stopped before the new one can start and two camera streams never overlap.
@MainActor
@Observable
final class CameraViewerModel {
    typealias MakeLiveModel = @MainActor (String) -> LiveCameraModel

    let cameraNames: [String]
    let snapshots: CameraGridModel
    private(set) var selectedCameraName: String
    private(set) var live: LiveCameraModel
    private(set) var isVisible = false
    private(set) var isMuted = true

    private let makeLiveModel: MakeLiveModel
    private var isSceneActive = true

    init(
        client: FrigateClient,
        config: FrigateConfig,
        initialCameraName: String,
        snapshots: CameraGridModel,
        makeLiveModel: MakeLiveModel? = nil
    ) {
        let names = snapshots.cameraNames
        let initial = names.contains(initialCameraName) ? initialCameraName : names.first ?? initialCameraName
        let builder: MakeLiveModel = makeLiveModel ?? { cameraName in
            LiveCameraModel(client: client, cameraName: cameraName, config: config)
        }

        cameraNames = names
        selectedCameraName = initial
        self.snapshots = snapshots
        self.makeLiveModel = builder
        live = builder(initial)
        live.setMuted(true)
    }

    var selectedSnapshot: CameraGridModel.SnapshotState {
        snapshots.snapshots[selectedCameraName] ?? .loading
    }

    var displayName: String {
        selectedCameraName
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    func appear() {
        guard !isVisible else { return }
        isVisible = true
        guard isSceneActive else { return }
        live.start()
    }

    func disappear() {
        guard isVisible else { return }
        isVisible = false
        live.stop()
    }

    func select(_ cameraName: String) {
        guard cameraName != selectedCameraName, cameraNames.contains(cameraName) else { return }

        live.stop()
        selectedCameraName = cameraName
        let replacement = makeLiveModel(cameraName)
        replacement.setMuted(isMuted)
        live = replacement

        if isVisible, isSceneActive {
            replacement.start()
        }
    }

    func toggleMuted() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        live.setMuted(muted)
    }

    func sceneBecameActive() {
        isSceneActive = true
        guard isVisible else { return }
        live.start()
    }

    func sceneEnteredBackground() {
        isSceneActive = false
        live.stop()
    }
}
