import SwiftUI

/// One row in the Events timeline. The thumbnail *is* the row - object type, relative time, and
/// camera are overlaid directly on the image instead of living in a text column beside it, so
/// the image gets the full row width. Tapping through drills into `ReviewDetailView`.
struct ReviewCardView: View {
    let client: FrigateClient
    let segment: ReviewSegment

    var body: some View {
        ReviewThumbnail(client: client, path: segment.thumbnailPath)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(alignment: .top) { scrim(edge: .top) }
            .overlay(alignment: .bottom) { scrim(edge: .bottom) }
            .overlay(alignment: .topLeading) {
                ObjectTypeBadge(objects: segment.data.objects)
                    .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                if !segment.hasBeenReviewed {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .padding(12)
                }
            }
            .overlay(alignment: .bottomLeading) {
                overlayLabel(segment.startDate.formatted(.relative(presentation: .named)))
                    .padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                overlayLabel(segment.camera.replacingOccurrences(of: "_", with: " ").capitalized)
                    .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// White text with a drop shadow, legible over any thumbnail without needing a solid
    /// background chip.
    private func overlayLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3)
    }

    /// Darkens just the top/bottom edges of the thumbnail so overlaid labels stay readable
    /// against bright footage, without dimming the image as a whole.
    private func scrim(edge: UnitPoint) -> some View {
        LinearGradient(
            colors: [.black.opacity(0.5), .clear],
            startPoint: edge,
            endPoint: .center
        )
        .frame(height: 60)
        .allowsHitTesting(false)
    }
}
