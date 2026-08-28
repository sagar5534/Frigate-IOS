import SwiftUI
import WebRTC

/// Hosts the player-owned `RTCMTLVideoView`.
///
/// The view is passed in rather than created here: `LivePlayer` conformers own their render surface
/// (see the protocol's note on why), so the Metal view's lifetime is tied to the peer connection
/// feeding it, not to a SwiftUI body that may be re-evaluated at any time.
///
/// A Metal view with nothing rendered into it yet is **transparent, not black**, which gives the
/// loading state for free: stack this over the camera's existing snapshot and the still simply shows
/// through until the first frame lands. The same trick the Recent Activity strip uses for
/// `AVPlayerLayer` (see `LEARNINGS.md`).
struct LiveVideoView: UIViewRepresentable {
    let renderer: RTCMTLVideoView

    func makeUIView(context: Context) -> RTCMTLVideoView {
        renderer
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}
