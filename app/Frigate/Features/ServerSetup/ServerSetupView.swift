import SwiftUI

struct ServerSetupView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model = ServerSetupModel()

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("nvr.local:8971", text: $model.urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .submitLabel(.go)
                        .onSubmit(connect)
                } header: {
                    Text("Frigate server address")
                } footer: {
                    Text(verbatim: "The address of your Frigate server, e.g. https://nvr.local:8971.")
                }

                Section {
                    Toggle("Allow insecure connections", isOn: $model.allowInsecure)
                } footer: {
                    Text("Skip TLS validation for a server using a self-signed certificate.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Text("Connect")
                            if model.isTesting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.isTesting || model.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Add Server")
        }
    }

    private var errorMessage: String? {
        if case .failed(let message) = model.phase { return message }
        return nil
    }

    private func connect() {
        Task { await model.testConnection(appModel) }
    }
}
