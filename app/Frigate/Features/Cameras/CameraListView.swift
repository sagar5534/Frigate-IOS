import SwiftUI

struct CameraListView: View {
    let client: FrigateClient
    @State private var model: CameraGridModel

    init(client: FrigateClient, cameraNames: [String]) {
        self.client = client
        _model = State(wrappedValue: CameraGridModel(client: client, cameraNames: cameraNames))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.cameraNames.isEmpty {
                    ContentUnavailableView(
                        "No Cameras",
                        systemImage: "video.slash",
                        description: Text("No enabled cameras were found on this server.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(model.cameraNames, id: \.self) { name in
                                NavigationLink {
                                    CameraDetailView(client: client, cameraName: name)
                                } label: {
                                    CameraRow(state: model.snapshots[name] ?? .loading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Cameras")
            .task { model.startAutoRefresh() }
            .onDisappear { model.stopAutoRefresh() }
        }
    }
}

private struct CameraRow: View {
    let state: CameraGridModel.SnapshotState

    var body: some View {
        SnapshotImage(state: state)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottomTrailing) {
                if let snapshot = state.snapshot {
                    SnapshotAgeBadge(capturedAt: snapshot.capturedAt)
                        .padding(8)
                }
            }
    }
}

/// Shared snapshot rendering for the camera row and the detail view: a material placeholder while
/// loading, the decoded JPEG once loaded, or an offline glyph on failure.
struct SnapshotImage: View {
    let state: CameraGridModel.SnapshotState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.thinMaterial)
            switch state {
            case .loading:
                ProgressView()
            case .loaded(let snapshot):
                if let image = UIImage(data: snapshot.data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            case .failed:
                Image(systemName: "video.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
    }
}
