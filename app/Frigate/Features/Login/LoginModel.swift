import Foundation
import Observation

/// Backs the login screen. Delegates the actual login + re-probe to `AppModel.submitLogin` and maps
/// failures to a user-facing message. On success, `AppModel.state` flips to `.connected` and the
/// login screen is replaced by the root view switch.
@MainActor
@Observable
final class LoginModel {
    enum Phase: Equatable {
        case idle
        case submitting
        case failed(String)
    }

    var username: String = ""
    var password: String = ""
    private(set) var phase: Phase = .idle

    var isSubmitting: Bool { phase == .submitting }

    func submit(_ appModel: AppModel) async {
        phase = .submitting
        do {
            try await appModel.submitLogin(user: username, password: password)
        } catch let error as APIError {
            phase = .failed(Self.message(for: error))
        } catch {
            phase = .failed("Something went wrong.")
        }
    }

    static func message(for error: APIError) -> String {
        switch error {
        case .unauthorized:
            return "Incorrect username or password."
        case .transport:
            return "Connection lost."
        default:
            return "Couldn't sign in. Please try again."
        }
    }
}
