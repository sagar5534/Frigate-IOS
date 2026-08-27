import SwiftUI

struct EventsView: View {
    let client: FrigateClient
    let cameraNames: [String]
    @State private var model: EventsModel
    @State private var showingFilters = false
    /// Day sections the user has collapsed, keyed by `Calendar.startOfDay`. Collapsing a day
    /// hides its cards so the next day's header slides up right underneath - the quickest way to
    /// skip past a day you've already seen.
    @State private var collapsedDays: Set<Date> = []

    init(client: FrigateClient, cameraNames: [String]) {
        self.client = client
        self.cameraNames = cameraNames
        _model = State(wrappedValue: EventsModel(client: client))
    }

    var body: some View {
        @Bindable var model = model
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
                        description: Text(
                            model.filters.isDefault
                                ? "Activity from the last 24 hours will appear here."
                                : "No activity matches your filters."
                        )
                    )
                case .loaded(let segments):
                    List {
                        ForEach(daySections(for: segments), id: \.day) { section in
                            Section {
                                if !collapsedDays.contains(section.day) {
                                    ForEach(section.segments) { segment in
                                        NavigationLink {
                                            ReviewDetailView(client: client, segment: segment, onUpdate: model.updateSegment)
                                        } label: {
                                            ReviewCardView(client: client, segment: segment)
                                        }
                                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .onAppear {
                                            guard segment.id == segments.last?.id else { return }
                                            Task { await model.loadMore() }
                                        }
                                    }
                                }
                            } header: {
                                dayHeader(section.day)
                            }
                        }
                        if model.isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await model.load() }
                }
            }
            .navigationTitle("Events")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFilters = true
                    } label: {
                        Image(systemName: model.filters.isDefault
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showingFilters) {
                EventFilterSheet(
                    filters: $model.filters,
                    cameraNames: cameraNames,
                    labelOptions: labelOptions
                )
            }
            .task(id: model.filters) { await model.load() }
        }
    }

    /// v1: derived from whatever is currently loaded, not a separate server call - so the label
    /// picker only offers labels actually seen in the current window/filters.
    private var labelOptions: [String] {
        guard case .loaded(let segments) = model.state else { return [] }
        return Array(Set(segments.flatMap(\.data.objects))).sorted()
    }

    /// Tappable section header - toggles that day's cards collapsed/expanded so the header
    /// doubles as a jump point to the next day.
    private func dayHeader(_ day: Date) -> some View {
        let isCollapsed = collapsedDays.contains(day)
        return Button {
            withAnimation(.snappy) {
                if isCollapsed {
                    collapsedDays.remove(day)
                } else {
                    collapsedDays.insert(day)
                }
            }
        } label: {
            HStack {
                Text(day.formatted(date: .abbreviated, time: .omitted))
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
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
