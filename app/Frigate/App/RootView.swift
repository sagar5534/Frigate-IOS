import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        switch appModel.state {
        case .disconnected:
            ServerSetupView()
        case .connecting:
            ProgressView("Connecting…")
        case .needsAuth:
            LoginView()
        case .connected(_, let config):
            MainPlaceholderView(config: config)
        }
    }
}

/// Temporary "you're connected" screen shown until the P2 main app lands. Confirms the round trip
/// by listing the camera names decoded from `/api/config`.
struct MainPlaceholderView: View {
    @Environment(AppModel.self) private var appModel
    let config: FrigateConfig

    var body: some View {
        NavigationStack {
            List {
                Section("Cameras") {
                    if config.cameras.isEmpty {
                        Text("No cameras configured.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(config.cameras.keys.sorted(), id: \.self) { name in
                            Text(name)
                        }
                    }
                }
            }
            .navigationTitle("Connected")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Log Out", role: .destructive) { appModel.logout() }
                }
            }
        }
    }
}
