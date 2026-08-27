import AVFoundation
import SwiftUI

/// A chrome-less, muted, endlessly-looping video view that fills its frame.
///
/// Designed to sit on top of a still image in a `ZStack` (see `RecentActivityCard`): an
/// `AVPlayerLayer` that hasn't produced a frame yet is transparent, so whatever is underneath
/// shows through while the video loads - and keeps showing if the video never loads at all.
/// Frigate returns 404 from the preview route when no preview file covers a segment's time range,
/// so that fallback isn't an edge case. It's why there's no "failed" branch to render here:
/// failure is just silence.
struct LoopingVideoPlayer: View {
    let client: FrigateClient
    let endpoint: Endpoint

    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = LoopingPlayerController()

    var body: some View {
        PlayerLayerView(player: controller.player, controller: controller)
            .opacity(controller.isReadyForDisplay ? 1 : 0)
            .animation(.easeIn(duration: 0.2), value: controller.isReadyForDisplay)
            // The hosting UIView would otherwise hit-test and swallow taps meant for the enclosing
            // NavigationLink. AVPlayerLayer has no gestures of its own, but the view still does.
            .allowsHitTesting(false)
            .task(id: endpoint.path) {
                await controller.start(client: client, endpoint: endpoint)
            }
            // Releases the decode session the moment the card leaves the strip. This is the whole
            // concurrency strategy, not just tidiness - see the note on `start`.
            .onDisappear { controller.teardown() }
            .onChange(of: scenePhase) { _, phase in
                controller.setActive(phase == .active)
            }
    }
}

/// Owns the player and the looper. Separate from the `View` because SwiftUI recreates view structs
/// freely and AVFoundation objects have to outlive that - in particular an `AVPlayerLooper` stops
/// looping the instant it deallocates.
@MainActor
@Observable
final class LoopingPlayerController {
    private(set) var player: AVQueuePlayer?
    /// True once the layer has actually put a frame on screen - not merely once `play()` was
    /// called. Both `play()` returning and `item.status == .readyToPlay` happen earlier, so
    /// crossfading on either of those shows a flash of empty layer.
    private(set) var isReadyForDisplay = false

    private var looper: AVPlayerLooper?
    private var wantsPlayback = false

    /// Builds and starts the player. Bails out silently on anything unplayable, leaving whatever
    /// is underneath in the `ZStack` on screen.
    ///
    /// iOS caps simultaneous hardware H.264 decode sessions - the practical number to design
    /// against is 3-4, and past it the failure is silent (an item reports `.readyToPlay` and
    /// renders black). A `LazyHStack` of 220pt cards realizes roughly 2 visible plus 1-2 buffered,
    /// which sits inside that budget only because `teardown()` runs promptly on `.onDisappear`.
    func start(client: FrigateClient, endpoint: Endpoint) async {
        teardown()
        guard let url = await client.authedURL(for: endpoint) else { return }
        // AVFoundation doesn't consult URLSession's cookie jar, so the session cookie has to be
        // handed over explicitly - same pattern as `ClipPlayerView`.
        let cookies = await client.sessionCookies(for: url)
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])

        // Loading these two up front does double duty: it turns a 404 (or any unplayable body)
        // into an early return here instead of a permanently black card later, and AVPlayerLooper
        // needs a known duration anyway.
        do {
            let (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
            guard isPlayable, duration.isNumeric, duration.seconds > 0 else { return }
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        // Otherwise a strip of perpetual loops holds the screen awake indefinitely.
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        // These clips are seconds long and usually served over the LAN; start now rather than
        // buffer ahead. Worth flipping back to `true` if previews stutter over a slow remote link.
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        // NOTE: deliberately NOT setting `actionAtItemEnd`. AVPlayerLooper depends on
        // AVQueuePlayer's default `.advance`; setting `.none` (the manual seek-to-zero idiom)
        // silently disables looping.

        // Rate stays at 1.0 - the server already compressed time ~8.33x when it rendered this
        // clip. See `Endpoint.reviewPreviewMP4`.
        looper = AVPlayerLooper(player: queuePlayer, templateItem: AVPlayerItem(asset: asset))
        player = queuePlayer
        wantsPlayback = true
        queuePlayer.play()
    }

    func setActive(_ active: Bool) {
        guard wantsPlayback, let player else { return }
        if active {
            player.play()
        } else {
            player.pause()
        }
    }

    func teardown() {
        wantsPlayback = false
        isReadyForDisplay = false
        // The looper holds the queue player, so releasing only `player` would leak the decode
        // pipeline it's still driving.
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
    }

    fileprivate func setReadyForDisplay(_ ready: Bool) {
        isReadyForDisplay = ready
    }
}

/// Hosts an `AVPlayerLayer` directly.
///
/// `AVKit.VideoPlayer` (what `ClipPlayerView` uses, correctly, for full-screen playback) is wrong
/// for a card: it draws a transport bar, installs a tap gesture recognizer that would swallow the
/// enclosing `NavigationLink`'s taps, letterboxes onto black with no aspect-fill option, and
/// carries an `AVPlayerViewController` per card.
private struct PlayerLayerView: UIViewRepresentable {
    /// Held as a stored property rather than read off `controller` inside the body, so the parent
    /// view registers the Observation dependency and SwiftUI actually calls `updateUIView` when
    /// the player is created.
    let player: AVQueuePlayer?
    let controller: LoopingPlayerController

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.observe(view.playerLayer, controller: controller)
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleUIView(_ view: PlayerHostView, coordinator: Coordinator) {
        coordinator.stop()
        view.playerLayer.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var observation: NSKeyValueObservation?

        func observe(_ layer: AVPlayerLayer, controller: LoopingPlayerController) {
            // KVO fires on an arbitrary thread, so this reads `change.newValue` rather than
            // touching the layer, and hops to the main actor to publish.
            observation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { @Sendable [weak controller] _, change in
                guard let ready = change.newValue else { return }
                Task { @MainActor in controller?.setReadyForDisplay(ready) }
            }
        }

        func stop() {
            observation = nil
        }
    }
}

/// Overriding `layerClass` makes the view's own backing layer the `AVPlayerLayer`, so it resizes
/// with the view for free - no frame bookkeeping in `layoutSubviews`.
private final class PlayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
