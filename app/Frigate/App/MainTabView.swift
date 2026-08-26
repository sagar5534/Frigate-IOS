import SwiftUI

/// The P2 main app shell, shown once `AppModel` reaches `.connected`.
struct MainTabView: View {
    let client: FrigateClient
    let config: FrigateConfig
    @Environment(AppModel.self) private var appModel

    var body: some View {
        TabView {
            CameraListView(client: client, cameraNames: config.enabledCameraNames)
                .tabItem { Label("Cameras", systemImage: "video") }

            EventsView(client: client, cameraNames: config.enabledCameraNames)
                .tabItem { Label("Events", systemImage: "list.bullet.rectangle") }

            SettingsView(baseURL: appModel.baseURL)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
