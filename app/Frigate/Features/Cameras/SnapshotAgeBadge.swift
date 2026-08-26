import SwiftUI

/// Bottom-right freshness badge for a camera image, in the spirit of Apple Home's snapshot age
/// label: "Now" for a just-fetched frame, then a relative time as it ages ("5s ago", "2m ago",
/// "1h ago", "1d ago") - always relative, never an absolute date/time.
struct SnapshotAgeBadge: View {
    let capturedAt: Date

    var body: some View {
        TimelineView(.periodic(from: capturedAt, by: 1)) { context in
            Text(Self.label(age: context.date.timeIntervalSince(capturedAt)))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
        }
    }

    /// A single cached formatter - `RelativeDateTimeFormatter` is expensive to allocate and this
    /// view redraws every second. Locale is pinned to en_US: nothing else in the app is localized
    /// (strings are hardcoded English throughout), and pinning keeps this label's wording
    /// deterministic across devices/regions instead of drifting with the system locale.
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    static func label(age: TimeInterval) -> String {
        guard age >= 2 else { return "Now" }
        if age < 60 {
            return "\(Int(age))s ago"
        }
        return formatter.localizedString(fromTimeInterval: -age)
    }
}
