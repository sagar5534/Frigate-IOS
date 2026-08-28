import SwiftUI

/// A camera's picture: the P2 snapshot underneath, live video over it, status on top.
///
/// **The snapshot is never removed while live runs.** An `RTCMTLVideoView` with no frame yet is
/// transparent, so the still simply shows through until the first frame lands - no crossfade to
/// tune, no flash of black, and when live drops the still is already in place rather than being
/// rebuilt from nothing. It also means a camera with no playable tier degrades to exactly the P2
/// experience instead of an error.
struct LiveCameraView: View {
    let snapshot: CameraGridModel.SnapshotState
    let live: LiveCameraModel

    var body: some View {
        ZStack {
            SnapshotImage(state: snapshot)

            if let player = live.player {
                player.view
            }

            LiveStatusOverlay(state: live.state, retry: live.retry)
        }
    }
}

/// What the live layer has to say for itself. Silent while playing, and silent when live simply
/// isn't available - in that case the snapshot below is the whole feature, and an error badge over
/// a perfectly good picture would be noise.
struct LiveStatusOverlay: View {
    let state: LivePlayerState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .playing, .idle:
            EmptyView()
        case .connecting:
            badge { ProgressView().controlSize(.small) ; Text("Connecting") }
        case .stalled:
            badge { ProgressView().controlSize(.small) ; Text("Reconnecting") }
        case .failed(let error):
            failure(error)
        }
    }

    @ViewBuilder
    private func failure(_ error: LivePlayerError) -> some View {
        switch error {
        case .notAvailable:
            // Deliberately nothing. The snapshot is still updating every few seconds, which is a
            // working camera view, and this is the expected state for a camera with no go2rtc
            // restream until the MJPEG tier (P4.2) ships.
            EmptyView()
        case .iceFailed:
            // The one failure with a cause worth naming. It is not transient and not our bug: the
            // media path is a direct connection on port 8555, separate from the HTTPS origin
            // everything else uses, and it is not reachable from this network.
            explanation(
                title: "Live video can't reach this camera",
                message: "The live stream needs port 8555 open to this device. The snapshot below keeps updating."
            )
        case .signalingFailed:
            explanation(
                title: "Couldn't start live video",
                message: "The server didn't answer the live connection. The snapshot below keeps updating."
            )
        case .noVideo:
            // Deliberately says nothing about the network: the connection demonstrably succeeded,
            // so the camera or its stream is what needs looking at.
            explanation(
                title: "No video from this camera",
                message: "The connection worked but the camera sent no video. The snapshot below keeps updating."
            )
        case .connectionLost:
            explanation(
                title: "Live video stopped",
                message: "The connection dropped and didn't recover."
            )
        }
    }

    private func explanation(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash")
                .font(.title2)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(16)
    }

    private func badge<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6, content: content)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(12)
    }
}
