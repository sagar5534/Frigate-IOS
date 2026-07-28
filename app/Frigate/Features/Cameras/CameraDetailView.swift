import SwiftUI

struct CameraDetailView: View {
    let cameraName: String
    @State private var model: CameraDetailModel

    init(client: FrigateClient, cameraName: String) {
        self.cameraName = cameraName
        _model = State(wrappedValue: CameraDetailModel(client: client, cameraName: cameraName))
    }

    var body: some View {
        ScrollView {
            SnapshotImage(state: model.state)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .padding()
        }
        .navigationTitle(cameraName.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.inline)
        .task { model.startAutoRefresh() }
        .onDisappear { model.stopAutoRefresh() }
    }
}
