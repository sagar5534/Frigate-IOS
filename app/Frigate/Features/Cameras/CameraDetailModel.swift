import Foundation
import Observation

/// Same auto-refresh loop as `CameraGridModel`, scoped to one camera at a larger snapshot size.
@MainActor
@Observable
final class CameraDetailModel {
    private(set) var state: CameraGridModel.SnapshotState = .loading

    private let client: FrigateClient
    private let cameraName: String
    private let height: Int?
    private var refreshTask: Task<Void, Never>?

    init(client: FrigateClient, cameraName: String, height: Int? = 720) {
        self.client = client
        self.cameraName = cameraName
        self.height = height
    }

    func startAutoRefresh(interval: Duration = .seconds(5)) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        do {
            let data = try await client.snapshot(camera: cameraName, height: height)
            state = .loaded(data)
        } catch {
            state = .failed
        }
    }
}
