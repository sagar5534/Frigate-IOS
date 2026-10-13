import SwiftUI

/// A full-screen, single-page live viewer. One camera is live at a time; the horizontal strip is
/// snapshots only and switches the focused player without adding another navigation destination.
struct CameraDetailView: View {
    @State private var model: CameraViewerModel
    @State private var centeredCameraName: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(client: FrigateClient, cameraName: String, config: FrigateConfig, snapshots: CameraGridModel) {
        let initialCameraName = snapshots.cameraNames.contains(cameraName)
            ? cameraName : snapshots.cameraNames.first ?? cameraName
        _model = State(wrappedValue: CameraViewerModel(
            client: client,
            config: config,
            initialCameraName: initialCameraName,
            snapshots: snapshots
        ))
        _centeredCameraName = State(initialValue: initialCameraName)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header

                Spacer(minLength: 20)

                LiveCameraView(snapshot: model.selectedSnapshot, live: model.live)
                    // UIViewRepresentable keeps the UIView returned by makeUIView for its
                    // lifetime. Each WebRTC player owns a different RTCMTLVideoView, so a
                    // camera switch must remount this subtree instead of only updating it.
                    .id(model.selectedCameraName)
                    .aspectRatio(model.live.videoAspectRatio ?? 16.0 / 9.0, contentMode: .fit)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: max(120, proxy.size.height - 230)
                    )
                    .background(Color.black)
                    .accessibilityLabel("\(model.displayName) live video")

                Spacer(minLength: 24)

                cameraStrip
                    .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .task { model.appear() }
        .onDisappear { model.disappear() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.sceneBecameActive()
            case .background:
                model.sceneEnteredBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                model.disappear()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close camera viewer")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                streamStatus
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.toggleMuted()
            } label: {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 54, height: 44)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!model.live.supportsAudio)
            .opacity(model.live.supportsAudio ? 1 : 0.45)
            .accessibilityLabel(audioAccessibilityLabel)
            .accessibilityHint(model.live.supportsAudio ? "Toggles camera audio" : "Audio is unavailable for this stream")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var audioAccessibilityLabel: String {
        guard model.live.supportsAudio else { return "Camera audio unavailable" }
        return model.isMuted ? "Unmute \(model.displayName)" : "Mute \(model.displayName)"
    }

    @ViewBuilder
    private var streamStatus: some View {
        switch model.live.state {
        case .playing:
            Label {
                Text("Live")
            } icon: {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("Live video connected")
        case .idle, .connecting:
            connectingStatus("Connecting")
        case .stalled:
            connectingStatus(model.live.hasEverPlayed ? "Reconnecting" : "Connecting")
        case .failed(let error):
            if error == .notAvailable {
                Label("Live unavailable", systemImage: "video.slash")
            } else if model.live.isAwaitingManualRetry {
                Label("Connection failed", systemImage: "exclamationmark.circle")
            } else {
                connectingStatus(model.live.hasEverPlayed ? "Reconnecting" : "Connecting")
            }
        }
    }

    private func connectingStatus(_ title: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }

    private var cameraStrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(model.cameraNames, id: \.self) { cameraName in
                    CameraThumbnailButton(
                        cameraName: cameraName,
                        state: model.snapshots.snapshots[cameraName] ?? .loading,
                        isSelected: cameraName == model.selectedCameraName
                    ) {
                        model.select(cameraName)
                    }
                    .id(cameraName)
                }
            }
            .padding(.horizontal, 18)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centeredCameraName, anchor: .center)
        .frame(height: 86)
        .onChange(of: model.selectedCameraName) { _, selected in
            withAnimation(reduceMotion ? nil : .snappy) {
                centeredCameraName = selected
            }
        }
    }
}

private struct CameraThumbnailButton: View {
    let cameraName: String
    let state: CameraGridModel.SnapshotState
    let isSelected: Bool
    let action: () -> Void

    private var displayName: String {
        cameraName
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    var body: some View {
        Button(action: action) {
            SnapshotImage(state: state)
                .frame(width: 142, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.14), lineWidth: isSelected ? 4 : 1)
                }
                .padding(3)
                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(displayName) camera")
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
