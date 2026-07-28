import SwiftUI

/// Stand-in for the P3 events timeline.
struct EventsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Events",
                systemImage: "list.bullet.rectangle",
                description: Text("Event browsing lands in P3.")
            )
            .navigationTitle("Events")
        }
    }
}
