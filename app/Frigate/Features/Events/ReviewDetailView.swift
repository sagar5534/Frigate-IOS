import SwiftUI

struct ReviewDetailView: View {
    let client: FrigateClient
    @State private var model: ReviewDetailModel
    @State private var showingClip = false

    init(client: FrigateClient, segment: ReviewSegment, onUpdate: @escaping (ReviewSegment) -> Void) {
        self.client = client
        _model = State(wrappedValue: ReviewDetailModel(segment: segment, client: client, onUpdate: onUpdate))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ReviewThumbnail(client: client, path: model.segment.thumbnailPath)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    metadataRow("Camera", model.segment.camera.replacingOccurrences(of: "_", with: " ").capitalized)
                    metadataRow("Severity", model.segment.severity.displayName)
                    metadataRow("Started", model.segment.startDate.formatted(date: .abbreviated, time: .shortened))
                    if let duration = model.segment.duration {
                        metadataRow("Duration", Self.durationFormatter.string(from: duration) ?? "-")
                    } else {
                        metadataRow("Status", "In progress")
                    }
                    if !model.segment.data.objects.isEmpty {
                        metadataRow("Objects", model.segment.objectSummary)
                    }
                    if !model.segment.data.zones.isEmpty {
                        metadataRow("Zones", model.segment.data.zones.map(\.capitalized).joined(separator: ", "))
                    }
                }

                Button {
                    showingClip = true
                } label: {
                    Label("Play Clip", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                // A still-open segment has no fixed end time to build a clip range from.
                .disabled(model.segment.isInProgress)

                Button {
                    Task { await model.toggleReviewed() }
                } label: {
                    HStack {
                        Text(model.segment.hasBeenReviewed ? "Mark Unreviewed" : "Mark Reviewed")
                        if model.isUpdatingReviewed {
                            Spacer()
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isUpdatingReviewed)

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle(model.segment.objectSummary)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingClip) {
            ClipPlayerView(
                client: client,
                camera: model.segment.camera,
                start: model.segment.startTime,
                end: model.segment.endTime ?? Date().timeIntervalSince1970
            )
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}
