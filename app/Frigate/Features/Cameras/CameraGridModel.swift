import Foundation
import Observation

/// Drives the camera list: holds one snapshot per camera and refreshes all of them concurrently
/// on a timer. `CameraDetailModel` uses the same client at a larger size for the single-camera view,
/// and shares `SnapshotState`/`Snapshot` and the staleness rule below via `SnapshotState.advanced`.
@MainActor
@Observable
final class CameraGridModel {
    /// A decoded frame plus when it was *fetched*. `/api/{camera}/latest.jpg` reports no capture
    /// time, so this is our own fetch time - close enough for a freshness badge, but not a claim
    /// about when the camera actually saw the frame.
    struct Snapshot: Equatable {
        let data: Data
        let capturedAt: Date
    }

    enum SnapshotState: Equatable {
        case loading
        case loaded(Snapshot)
        case failed
    }

    let cameraNames: [String]
    private(set) var snapshots: [String: SnapshotState]

    private let client: FrigateClient
    private let thumbnailHeight: Int
    private let now: () -> Date
    private var refreshTask: Task<Void, Never>?

    init(
        client: FrigateClient,
        cameraNames: [String],
        thumbnailHeight: Int = 720,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.cameraNames = cameraNames
        self.thumbnailHeight = thumbnailHeight
        self.now = now
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
        await withTaskGroup(of: (String, Result<Data, Error>).self) { group in
            for name in cameraNames {
                group.addTask {
                    do {
                        return (name, .success(try await client.snapshot(camera: name, height: height)))
                    } catch {
                        return (name, .failure(error))
                    }
                }
            }
            let fetchedAt = now()
            for await (name, result) in group {
                let previous = snapshots[name] ?? .loading
                snapshots[name] = previous.advanced(with: result, fetchedAt: fetchedAt)
            }
        }
    }
}

extension CameraGridModel.SnapshotState {
    var snapshot: CameraGridModel.Snapshot? {
        if case .loaded(let snapshot) = self { return snapshot }
        return nil
    }

    /// The shared staleness rule for both `CameraGridModel` and `CameraDetailModel`:
    /// - Identical bytes to the currently-held frame mean the stream is stuck, not that a fresh
    ///   frame just arrived - keep the existing `capturedAt` so the age badge keeps climbing rather
    ///   than resetting to "Now" every poll.
    /// - A failed fetch does not blank a good image - keep showing the last loaded frame (its age
    ///   keeps climbing) and only fall to `.failed` when nothing has ever loaded.
    func advanced(with result: Result<Data, Error>, fetchedAt: Date) -> Self {
        switch result {
        case .success(let data):
            if case .loaded(let previous) = self, previous.data == data {
                return self
            }
            return .loaded(CameraGridModel.Snapshot(data: data, capturedAt: fetchedAt))
        case .failure:
            if case .loaded = self {
                return self
            }
            return .failed
        }
    }
}
