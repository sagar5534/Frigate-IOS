import Foundation

/// A declarative description of one Frigate HTTP request. `path` is relative to `<baseURL>/api/`
/// (e.g. `"config"`, `"login"`). Adding a new API is a matter of adding one builder here plus a
/// `Codable` model.
nonisolated struct Endpoint: Sendable {
    var path: String
    var method: HTTPMethod = .get
    var query: [URLQueryItem] = []
    var body: Data? = nil
    var headers: [String: String] = [:]
}

nonisolated extension Endpoint {
    static var config: Endpoint {
        Endpoint(path: "config")
    }

    static func login(_ body: LoginRequest) throws -> Endpoint {
        let data = try JSONEncoder().encode(body)
        return Endpoint(
            path: "login",
            method: .post,
            body: data,
            headers: ["Content-Type": "application/json"]
        )
    }
    
    
}
