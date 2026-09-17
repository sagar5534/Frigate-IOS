import AVFoundation
import SwiftUI
import UIKit

/// The MSE tier's render surface: a UIView backed by `AVSampleBufferDisplayLayer`.
///
/// Owned by `MSELivePlayer`, not created in SwiftUI - same reasoning as `LiveVideoView`: the
/// layer's lifetime is tied to the decode pipeline feeding it, not to a body that can be
/// re-evaluated at any time. And like a Metal view, the layer is **transparent until it renders**,
/// so the snapshot underneath shows through until real frames arrive.
final class SampleBufferDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Matches RTCMTLVideoView's `.scaleAspectFill`, so a WebRTC -> MSE escalation doesn't
        // visibly reframe the picture.
        displayLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Hosts the player-owned `SampleBufferDisplayView` in SwiftUI.
struct SampleBufferVideoView: UIViewRepresentable {
    let view: SampleBufferDisplayView

    func makeUIView(context: Context) -> SampleBufferDisplayView {
        view
    }

    func updateUIView(_ uiView: SampleBufferDisplayView, context: Context) {}
}
