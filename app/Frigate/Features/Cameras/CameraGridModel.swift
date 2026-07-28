import Foundation
import Observation

/// Drives the camera grid: holds one snapshot per camera and refreshes all of them concurrently
/// on a timer. A thumbnail-sized `height` keeps grid refreshes cheap; `CameraDetailModel` uses the
/// same client at a larger size for the single-camera view.
@MainActor
@Observable
final class CameraGridModel {
    enum SnapshotState: Equatable {
        case loading
        case loaded(Data)
        case failed
    }

    let cameraNames: [String]
    private(set) var snapshots: [String: SnapshotState]

    private let client: FrigateClient
    private let thumbnailHeight: Int
    private var refreshTask: Task<Void, Never>?

    init(client: FrigateClient, cameraNames: [String], thumbnailHeight: Int = 300) {
        self.client = client
        self.cameraNames = cameraNames
        self.thumbnailHeight = thumbnailHeight
        self.snapshots = Dictionary(uniqueKeysWithValues: cameraNames.map { ($0, .loading) })
    }

    /// Fetches once immediately, then repeats every `interval` until `stopAutoRefresh()` is called.
    /// This spawns an unstructured `Task`, not a child of any SwiftUI `.task` - it is NOT cancelled
    /// by that view's `.task` being torn down. Callers must pair this with `stopAutoRefresh()` in
    /// `.onDisappear` (see `CameraGridView`); the `refreshTask == nil` guard below just prevents a
    /// second loop if `.task` re-runs while one is already active.
    func startAutoRefresh(interval: Duration = .seconds(5)) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshAll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refreshAll() async {
        let client = self.client
        let height = self.thumbnailHeight
        await withTaskGroup(of: (String, SnapshotState).self) { group in
            for name in cameraNames {
                group.addTask {
                    do {
                        let data = try await client.snapshot(camera: name, height: height)
                        return (name, .loaded(data))
                    } catch {
                        return (name, .failed)
                    }
                }
            }
            for await (name, state) in group {
                snapshots[name] = state
            }
        }
    }
}
