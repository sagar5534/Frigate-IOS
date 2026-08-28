import SwiftUI

/// One camera, full size. Live video plays here and only here - the camera list stays on the P2
/// snapshot loop, so exactly one peer connection exists at a time (the "never live-stream a grid"
/// rule in `CLAUDE.md`).
struct CameraDetailView: View {
    let cameraName: String
    @State private var snapshotModel: CameraDetailModel
    @State private var liveModel: LiveCameraModel
    @State private var isFullscreen = false
    @Environment(\.scenePhase) private var scenePhase

    init(client: FrigateClient, cameraName: String, config: FrigateConfig) {
        self.cameraName = cameraName
        _snapshotModel = State(wrappedValue: CameraDetailModel(client: client, cameraName: cameraName))
        _liveModel = State(wrappedValue: LiveCameraModel(client: client, cameraName: cameraName, config: config))
    }

    var body: some View {
        Group {
            if isFullscreen {
                fullscreenPlayer
            } else {
                inlinePlayer
            }
        }
        .navigationTitle(cameraName.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbar(isFullscreen ? .hidden : .visible, for: .tabBar)
        .statusBarHidden(isFullscreen)
        .task {
            snapshotModel.startAutoRefresh()
            liveModel.start()
        }
        .onDisappear {
            // Navigating away must close the peer connection. Without this the socket, the ICE
            // agent and the decoder all keep running behind whatever screen comes next.
            liveModel.stop()
            snapshotModel.stopAutoRefresh()
        }
        .onChange(of: liveModel.isPlaying) { _, isPlaying in
            // The snapshot underneath is the fallback, not the picture, once video is flowing -
            // and re-decoding a JPEG every 5s behind a live stream is pure waste.
            if isPlaying {
                snapshotModel.stopAutoRefresh()
            } else {
                snapshotModel.startAutoRefresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                liveModel.start()
            case .background, .inactive:
                // A backgrounded app cannot render video, and iOS will suspend it holding an open
                // peer connection and a decode session. Tear down and rebuild on return.
                liveModel.stop()
            @unknown default:
                break
            }
        }
    }

    private var inlinePlayer: some View {
        ScrollView {
            picture
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) { freshnessBadge }
                .padding()
        }
    }

    private var fullscreenPlayer: some View {
        ZStack {
            Color.black
            // Shaped to the stream, not to the screen. These cameras are wide; letting a 16:9 feed
            // fill a tall phone crops most of the frame away, which is the opposite of what someone
            // asks for when they tap to expand.
            picture
                .aspectRatio(liveModel.videoAspectRatio ?? 16.0 / 9.0, contentMode: .fit)
        }
        .ignoresSafeArea()
    }

    private var picture: some View {
        LiveCameraView(snapshot: snapshotModel.state, live: liveModel)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy) { isFullscreen.toggle() }
            }
    }

    /// Only meaningful while the still *is* the picture. Once live is playing the timestamp
    /// describes a frame nobody is looking at any more.
    @ViewBuilder
    private var freshnessBadge: some View {
        if !liveModel.isPlaying, let snapshot = snapshotModel.state.snapshot {
            SnapshotAgeBadge(capturedAt: snapshot.capturedAt)
                .padding(8)
        }
    }
}
