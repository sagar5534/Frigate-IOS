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
        case .connected(let client, let config):
            MainTabView(client: client, config: config)
        }
    }
}
