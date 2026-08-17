import SwiftUI

/// One row in the Events timeline: thumbnail, severity, camera, what was seen, and when.
struct ReviewCardView: View {
    let client: FrigateClient
    let segment: ReviewSegment

    var body: some View {
        HStack(spacing: 12) {
            ReviewThumbnail(client: client, path: segment.thumbnailPath)
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SeverityChip(severity: segment.severity)
                    Text(segment.camera.replacingOccurrences(of: "_", with: " "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(segment.objectSummary)
                    .font(.headline)
                Text(segment.startDate, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !segment.hasBeenReviewed {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SeverityChip: View {
    let severity: ReviewSegment.Severity

    var body: some View {
        Text(severity.displayName)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((severity == .alert ? Color.red : Color.gray).opacity(0.15))
            .foregroundStyle(severity == .alert ? .red : .secondary)
            .clipShape(Capsule())
    }
}
