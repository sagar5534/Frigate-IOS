import SwiftUI

/// One camera, full size. Live video plays here and only here - the camera list stays on the P2
/// snapshot loop, so exactly one peer connection exists at a time (the "never live-stream a grid"
/// rule in `CLAUDE.md`).
struct CameraDetailView: View {
    let cameraName: String
    @State private var snapshotModel: CameraDetailModel
    @State private var liveModel: LiveCameraModel
    @State private var isFullscreen = false
    /// Whether this screen is actually on-screen. A detail view the user navigated away from stays
    /// in the hierarchy and keeps receiving scene-phase changes, so without this a backgrounded and
    /// then foregrounded app would start live video for a camera nobody is looking at - and with no
    /// `onDisappear` left to fire, nothing would ever stop it.
    @State private var isVisible = false
    @Environment(\.scenePhase) private var scenePhase

    init(client: FrigateClient, cameraName: String, config: FrigateConfig) {
        self.cameraName = cameraName
        _snapshotModel = State(wrappedValue: CameraDetailModel(client: client, cameraName: cameraName))
        _liveModel = State(wrappedValue: LiveCameraModel(client: client, cameraName: cameraName, config: config))
    }

    var body: some View {
        // Deliberately not an if/else over two branches: both would be mounted during the
        // transition and both would call `makeUIView`, handing the *same* `RTCMTLVideoView` to two
        // representables. A UIView has one superview, so the second would steal it from the first.
        inlinePlayer
        .navigationTitle(cameraName.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbar(isFullscreen ? .hidden : .visible, for: .tabBar)
        .statusBarHidden(isFullscreen)
        .task {
            isVisible = true
            snapshotModel.startAutoRefresh()
            liveModel.start()
        }
        .onDisappear {
            // Navigating away must close the peer connection. Without this the socket, the ICE
            // agent and the decoder all keep running behind whatever screen comes next.
            isVisible = false
            liveModel.stop()
            snapshotModel.stopAutoRefresh()
        }
        .onChange(of: liveModel.isPlaying) { _, isPlaying in
            // The snapshot underneath is the fallback, not the picture, once video is flowing -
            // and re-decoding a JPEG every 5s behind a live stream is pure waste.
            //
            // Guarded on visibility because `stop()` flips this false: tearing down for any reason,
            // including going to the background, would otherwise *start* a 5s polling loop on a
            // screen nobody can see.
            guard isVisible, scenePhase == .active else { return }
            if isPlaying {
                snapshotModel.stopAutoRefresh()
            } else {
                snapshotModel.startAutoRefresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard isVisible else { return }
                liveModel.start()
                if !liveModel.isPlaying {
                    snapshotModel.startAutoRefresh()
                }
            case .background:
                // A backgrounded app cannot render video, and iOS will suspend it holding an open
                // peer connection and a decode session. Tear down and rebuild on return.
                //
                // `.inactive` is deliberately excluded. iOS sends it for the app switcher, a
                // Control Centre pull, an incoming call banner - moments the user is still looking
                // at the app. Tearing down for those costs a full re-handshake and a second of
                // black every time someone glances away, and resets the reconnect budget with it.
                liveModel.stop()
                snapshotModel.stopAutoRefresh()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    /// One view hierarchy for both presentations; only the framing changes.
    ///
    /// Fullscreen is shaped to the stream, not to the screen. These cameras are wide, and letting a
    /// 16:9 feed fill a tall phone crops most of the frame away - the opposite of what someone asks
    /// for when they tap to expand.
    private var inlinePlayer: some View {
        ScrollView {
            picture
                .aspectRatio(
                    isFullscreen ? (liveModel.videoAspectRatio ?? 16.0 / 9.0) : 16.0 / 9.0,
                    contentMode: .fit
                )
                .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : 12))
                .overlay(alignment: .bottomTrailing) { freshnessBadge }
                .padding(isFullscreen ? 0 : 16)
                .frame(maxWidth: .infinity)
                // Centres the video when expanded. `maxHeight: .infinity` would not: a ScrollView
                // proposes unbounded height to its content, so the frame resolves to the content's
                // ideal size and lays out top-aligned. `containerRelativeFrame` measures the scroll
                // view's visible height instead, which is the thing we actually want to fill.
                .modifier(FullscreenFill(isActive: isFullscreen))
        }
        .scrollDisabled(isFullscreen)
        .background(isFullscreen ? Color.black : Color.clear)
        .ignoresSafeArea(edges: isFullscreen ? .all : [])
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


/// Makes its content fill the scroll container's visible height and centre within it, but only
/// while fullscreen - inline, the picture should size to its own aspect ratio and nothing more.
private struct FullscreenFill: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.containerRelativeFrame(.vertical, alignment: .center)
        } else {
            content
        }
    }
}
