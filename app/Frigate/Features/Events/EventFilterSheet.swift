import SwiftUI

struct EventFilterSheet: View {
    @Binding var filters: EventFilters
    let cameraNames: [String]
    let labelOptions: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Severity") {
                    Picker("Severity", selection: $filters.severity) {
                        Text("All").tag(ReviewSegment.Severity?.none)
                        Text("Alerts").tag(ReviewSegment.Severity?.some(.alert))
                        Text("Detections").tag(ReviewSegment.Severity?.some(.detection))
                    }
                    .pickerStyle(.segmented)
                }

                Section("Time Range") {
                    Picker("Time Range", selection: $filters.timeRange) {
                        ForEach(EventFilters.TimeRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                }

                if !cameraNames.isEmpty {
                    Section("Cameras") {
                        ForEach(cameraNames, id: \.self) { name in
                            MultiSelectRow(
                                title: name.replacingOccurrences(of: "_", with: " "),
                                isSelected: filters.cameras.contains(name)
                            ) {
                                toggle(name, in: $filters.cameras)
                            }
                        }
                    }
                }

                if !labelOptions.isEmpty {
                    Section("Labels") {
                        ForEach(labelOptions, id: \.self) { label in
                            MultiSelectRow(
                                title: label.capitalized,
                                isSelected: filters.labels.contains(label)
                            ) {
                                toggle(label, in: $filters.labels)
                            }
                        }
                    }
                }

                if !filters.isDefault {
                    Section {
                        Button("Reset Filters", role: .destructive) {
                            filters = EventFilters()
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func toggle(_ value: String, in set: Binding<Set<String>>) {
        if set.wrappedValue.contains(value) {
            set.wrappedValue.remove(value)
        } else {
            set.wrappedValue.insert(value)
        }
    }
}

private struct MultiSelectRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
