import SwiftUI

/// One card in the Recent Activity strip: the segment's preview clip looping over its still
/// thumbnail, with the same overlay treatment as `ReviewCardView` uses in the Events timeline.
///
/// The `ZStack` ordering is the load-bearing part. `ReviewThumbnail` is a small webp that loads
/// fast; the video layer above it is transparent until its first frame decodes. So the thumbnail
/// doubles as the loading state *and* as the fallback for segments whose preview the server
/// doesn't have (`Endpoint.reviewPreviewMP4` 404s in that case) - a card that can't play just
/// stays a still image, with no black frame and no separate error branch.
struct RecentActivityCard: View {
    let client: FrigateClient
    let segment: ReviewSegment

    /// Preview clips are 180px tall (~320px wide), so this is roughly a 2x upscale on a 2x screen.
    /// That reads fine on moving footage; much wider and the softness starts to show against the
    /// sharp thumbnail underneath.
    private static let width: CGFloat = 220

    var body: some View {
        ZStack {
            ReviewThumbnail(client: client, path: segment.thumbnailPath)
            LoopingVideoPlayer(client: client, endpoint: .reviewPreviewMP4(id: segment.id))
        }
        .frame(width: Self.width, height: Self.width * 9 / 16)
        .overlay(alignment: .bottom) { scrim }
        .overlay(alignment: .bottomTrailing) {
            overlayLabel(segment.startDate.formatted(.relative(presentation: .named)))
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// White text with a drop shadow, legible over any footage without needing a solid chip -
    /// same treatment as `ReviewCardView`.
    private func overlayLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3)
            .lineLimit(1)
    }

    /// Darkens only the bottom edge, where the relative-time label sits.
    private var scrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.55), .clear],
            startPoint: .bottom,
            endPoint: .center
        )
        .frame(height: 50)
        .allowsHitTesting(false)
    }
}
