import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    let baseURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("URL", value: baseURL?.absoluteString ?? "Unknown")
                    LabeledContent("Status", value: "Connected")
                }

                Section {
                    Button("Log Out", role: .destructive) {
                        appModel.logout()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
