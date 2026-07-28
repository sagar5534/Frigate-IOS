import AVKit
import SwiftUI

/// Full-screen clip playback for a review segment. Uses the HLS VOD manifest
/// (`Endpoint.reviewClipHLS`), not the progressive `clip.mp4` route: Frigate's own server pipes
/// `clip.mp4` live from ffmpeg without a fixed `Content-Length` or HTTP Range support, so AVPlayer
/// can't reliably determine duration or seek on it - and the route's own description says iOS
/// should use the HLS link instead of it.
///
/// Cookie auth is passed via `AVURLAssetHTTPCookiesKey` since AVFoundation doesn't consult
/// `URLSession`'s cookie jar. This covers the HLS *segment* fetches, not just the manifest:
/// Frigate's nginx emits same-host relative segment URLs (`vod_base_url`/`vod_segments_base_url`
/// are both empty) and gates every request under `/vod/` - manifest and each segment alike -
/// through the same cookie-forwarding `auth_request` used by the already-verified thumbnail path
/// (see `Endpoint.reviewThumbnail`), independent of nginx-vod-module's `secure_token` directive
/// (that directive just passes a request's own query string through to its generated segment
/// URLs; our request has none, so it's a no-op here). Same-host relative URLs + an explicit
/// cookie list at `AVURLAsset` construction is the standard Apple-documented pattern for
/// authenticating HLS behind a cookie session.
struct ClipPlayerView: View {
    let client: FrigateClient
    let camera: String
    let start: Double
    let end: Double

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case playing(AVPlayer)
        case failed
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            switch state {
            case .loading:
                ProgressView()
                    .tint(.white)
            case .playing(let player):
                VideoPlayer(player: player)
            case .failed:
                ContentUnavailableView(
                    "Couldn't Load Clip",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Check your connection and try again.")
                )
                .foregroundStyle(.white)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding()
        }
        .task { await loadPlayer() }
        .onDisappear {
            if case .playing(let player) = state {
                player.pause()
            }
            state = .loading
        }
    }

    private func loadPlayer() async {
        guard let url = await client.authedURL(for: .reviewClipHLS(camera: camera, start: start, end: end)) else {
            state = .failed
            return
        }
        let cookies = await client.sessionCookies(for: url)
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        state = .playing(player)
        player.play()
    }
}
