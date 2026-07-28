import SwiftUI

struct EventsView: View {
    let client: FrigateClient
    @State private var model: EventsModel

    init(client: FrigateClient) {
        self.client = client
        _model = State(wrappedValue: EventsModel(client: client))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView()
                case .failed:
                    ContentUnavailableView {
                        Label("Couldn't Load Events", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Check your connection and try again.")
                    } actions: {
                        Button("Retry") { Task { await model.load() } }
                    }
                case .loaded(let segments) where segments.isEmpty:
                    ContentUnavailableView(
                        "No Recent Activity",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Activity from the last 24 hours will appear here.")
                    )
                case .loaded(let segments):
                    List {
                        ForEach(daySections(for: segments), id: \.day) { section in
                            Section(section.day.formatted(date: .abbreviated, time: .omitted)) {
                                ForEach(section.segments) { segment in
                                    ReviewCardView(client: client, segment: segment)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await model.load() }
                }
            }
            .navigationTitle("Events")
            .task { await model.load() }
        }
    }

    /// Segments are already newest-first; group into calendar-day sections without re-sorting
    /// within a day.
    private func daySections(for segments: [ReviewSegment]) -> [(day: Date, segments: [ReviewSegment])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [ReviewSegment]] = [:]
        for segment in segments {
            let day = calendar.startOfDay(for: segment.startDate)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(segment)
        }
        return order.map { (day: $0, segments: byDay[$0] ?? []) }
    }
}
