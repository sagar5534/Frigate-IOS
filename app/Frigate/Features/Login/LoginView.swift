import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model = LoginModel()

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $model.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(submit)
                } header: {
                    Text("Sign in")
                } footer: {
                    if let host = appModel.baseURL?.host() {
                        Text(verbatim: host)
                    }
                }

                if case .failed(let message) = model.phase {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Text("Sign In")
                            if model.isSubmitting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.isSubmitting || model.username.isEmpty || model.password.isEmpty)
                }
            }
            .navigationTitle("Login")
        }
    }

    private func submit() {
        Task { await model.submit(appModel) }
    }
}
