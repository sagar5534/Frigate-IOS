import Foundation
import Observation

/// Same auto-refresh loop and staleness rule as `CameraGridModel` (see
/// `CameraGridModel.SnapshotState.advanced(with:fetchedAt:)`), scoped to one camera at a larger
/// snapshot size.
@MainActor
@Observable
final class CameraDetailModel {
    private(set) var state: CameraGridModel.SnapshotState = .loading

    private let client: FrigateClient
    private let cameraName: String
    private let height: Int?
    private let now: () -> Date
    private var refreshTask: Task<Void, Never>?

    init(
        client: FrigateClient,
        cameraName: String,
        height: Int? = 720,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.cameraName = cameraName
        self.height = height
        self.now = now
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
        let result: Result<Data, Error>
        do {
            result = .success(try await client.snapshot(camera: cameraName, height: height))
        } catch {
            result = .failure(error)
        }
        state = state.advanced(with: result, fetchedAt: now())
    }
}
