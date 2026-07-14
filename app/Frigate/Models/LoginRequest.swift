import Foundation

nonisolated struct LoginRequest: Encodable, Sendable {
    let user: String
    let password: String
}
