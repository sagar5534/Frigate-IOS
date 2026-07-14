import Foundation

struct LoginRequest: Encodable, Sendable {
    let user: String
    let password: String
}
