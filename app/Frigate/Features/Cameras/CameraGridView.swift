import SwiftUI

struct CameraGridView: View {
    let client: FrigateClient
    @State private var model: CameraGridModel

    init(client: FrigateClient, cameraNames: [String]) {
        self.client = client
        _model = State(wrappedValue: CameraGridModel(client: client, cameraNames: cameraNames))
    }

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

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
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.cameraNames, id: \.self) { name in
                                NavigationLink {
                                    CameraDetailView(client: client, cameraName: name)
                                } label: {
                                    CameraTile(name: name, state: model.snapshots[name] ?? .loading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle("Cameras")
            .task { model.startAutoRefresh() }
            .onDisappear { model.stopAutoRefresh() }
        }
    }
}

private struct CameraTile: View {
    let name: String
    let state: CameraGridModel.SnapshotState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SnapshotImage(state: state)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(name.replacingOccurrences(of: "_", with: " "))
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
    }
}

/// Shared snapshot rendering for the grid tile and the detail view: a material placeholder while
/// loading, the decoded JPEG once loaded, or an offline glyph on failure.
struct SnapshotImage: View {
    let state: CameraGridModel.SnapshotState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.thinMaterial)
            switch state {
            case .loading:
                ProgressView()
            case .loaded(let data):
                if let image = UIImage(data: data) {
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
