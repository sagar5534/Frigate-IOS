import SwiftUI

/// Fetches a review segment's thumbnail through the authenticated client and renders it - like
/// `AsyncImage`, but routed through `FrigateClient` so cookie auth (and 401 retry) applies. A
/// segment's thumbnail is a fixed snapshot of when the activity happened, so a one-time fetch per
/// `path` is enough; no auto-refresh loop like the live camera snapshots.
struct ReviewThumbnail: View {
    let client: FrigateClient
    let path: String

    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded(UIImage)
        case failed
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.thinMaterial)
            switch state {
            case .loading:
                ProgressView()
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failed:
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: path) {
            state = .loading
            do {
                let data = try await client.reviewThumbnail(path: path)
                state = UIImage(data: data).map(LoadState.loaded) ?? .failed
            } catch {
                state = .failed
            }
        }
    }
}
