import SwiftUI

/// A horizontal row of looping preview clips for the last hour of unreviewed alerts, shown above
/// the camera list. Mirrors the strip Frigate's own PWA puts at the top of its live dashboard.
///
/// Self-contained: hand it a client and the cameras to watch and it manages its own polling,
/// empty state, and navigation. It renders to zero height when there's nothing recent, so the
/// host doesn't need to know whether it has anything to show.
///
/// Must be placed inside a `NavigationStack` - tapping a card pushes `ReviewDetailView` onto it.
struct RecentActivityStrip: View {
    let client: FrigateClient
    @State private var model: RecentActivityModel

    init(client: FrigateClient, cameraNames: [String]) {
        self.client = client
        _model = State(wrappedValue: RecentActivityModel(client: client, cameraNames: cameraNames))
    }

    var body: some View {
        // A VStack, not a Group. Group forwards modifiers to its children, so when the `if` below
        // produces nothing there are no children to attach to - `.task` would never run and the
        // strip would never load its first page. A VStack always exists.
        VStack(alignment: .leading, spacing: 8) {
            if !model.segments.isEmpty {
                Text("Recent Activity")
                    .font(.headline)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(model.segments) { segment in
                            NavigationLink {
                                ReviewDetailView(client: client, segment: segment, onUpdate: model.apply)
                            } label: {
                                RecentActivityCard(client: client, segment: segment)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // The inset lives on the HStack rather than the ScrollView so cards scroll
                    // right up to the screen edges, while the first one still lines up with the
                    // camera rows below.
                    .padding(.horizontal, 16)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .padding(.bottom, 4)
            }
        }
        .padding(.top, model.segments.isEmpty ? 0 : 12)
        .task { model.startAutoRefresh() }
        .onDisappear { model.stopAutoRefresh() }
    }
}
