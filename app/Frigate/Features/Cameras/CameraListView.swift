import SwiftUI

struct CameraListView: View {
    let client: FrigateClient
    let config: FrigateConfig
    @State private var model: CameraGridModel
    @State private var presentedCamera: CameraPresentation?
    @State private var isVisible = false
    @Environment(\.scenePhase) private var scenePhase

    init(client: FrigateClient, config: FrigateConfig) {
        self.client = client
        self.config = config
        _model = State(wrappedValue: CameraGridModel(client: client, cameraNames: config.enabledCameraNames))
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
                        // spacing: 0 is load-bearing. The strip renders to zero height when there
                        // is no recent activity, and any spacing here would leave a phantom gap
                        // above the first camera row on a quiet server.
                        VStack(spacing: 0) {
                            // Sits outside the LazyVStack's padding so it can bleed to the screen
                            // edges; it applies its own 16pt inset to line the first card up with
                            // the camera rows.
                            RecentActivityStrip(client: client, cameraNames: model.cameraNames)

                            LazyVStack(spacing: 16) {
                                ForEach(model.cameraNames, id: \.self) { name in
                                    Button {
                                        presentedCamera = CameraPresentation(cameraName: name)
                                    } label: {
                                        CameraRow(state: model.snapshots[name] ?? .loading)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Open \(name.replacingOccurrences(of: "_", with: " ")) camera")
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
            .navigationTitle("Cameras")
            .onAppear {
                isVisible = true
                if scenePhase == .active { model.startAutoRefresh() }
            }
            .onDisappear {
                // The full-screen viewer shares this store and still needs its updates.
                guard presentedCamera == nil else { return }
                isVisible = false
                model.stopAutoRefresh()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    if isVisible || presentedCamera != nil { model.startAutoRefresh() }
                case .background:
                    model.stopAutoRefresh()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .fullScreenCover(item: $presentedCamera, onDismiss: {
                if scenePhase == .active, isVisible { model.startAutoRefresh() }
            }) { presentation in
                CameraDetailView(
                    client: client,
                    cameraName: presentation.cameraName,
                    config: config,
                    snapshots: model
                )
            }
        }
    }
}

private struct CameraPresentation: Identifiable {
    let cameraName: String
    var id: String { cameraName }
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
    var contentMode: ContentMode = .fill

    var body: some View {
        ZStack {
            if contentMode == .fit {
                Color.black
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.thinMaterial)
            }
            switch state {
            case .loading:
                ProgressView()
            case .loaded(let snapshot):
                if let image = UIImage(data: snapshot.data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
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
