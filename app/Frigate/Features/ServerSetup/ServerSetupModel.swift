import Foundation
import Observation

/// Backs the "add your server" screen. Normalizes the typed address and hands it to
/// `AppModel.connect`, which owns the reachability probe + http:// fallback and the state
/// transition. On failure `AppModel` leaves its state untouched, so this screen (and the typed
/// input) stays mounted while showing the error.
@MainActor
@Observable
final class ServerSetupModel {
    enum Phase: Equatable {
        case idle
        case testing
        case failed(String)
    }

    var urlText: String = ""
    var allowInsecure: Bool = false
    private(set) var phase: Phase = .idle

    var isTesting: Bool { phase == .testing }

    func testConnection(_ appModel: AppModel) async {
        phase = .testing

        let baseURL: URL
        do {
            baseURL = try ServerURL.normalize(urlText)
        } catch {
            phase = .failed("Enter a valid address.")
            return
        }

        do {
            try await appModel.connect(baseURL: baseURL, allowInsecure: allowInsecure)
            phase = .idle // success: the root view switches away from this screen
        } catch let error as APIError {
            phase = .failed(Self.message(for: error))
        } catch {
            phase = .failed("Couldn't reach a Frigate server there.")
        }
    }

    static func message(for error: APIError) -> String {
        switch error {
        case .transport, .invalidURL:
            return "Couldn't reach a Frigate server there."
        case .http, .decoding, .authDisabled, .unauthorized, .notConnected:
            return "That server didn't respond like Frigate."
        }
    }
}
