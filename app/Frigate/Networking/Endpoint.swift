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

    /// The latest decoded frame for a camera, falling back server-side to the most recent preview
    /// frame (or an error placeholder image) if the camera is offline. The server still returns a
    /// non-200 (400 invalid params, 404 unknown camera, 500 no frame available) in some cases, so
    /// callers must handle failure, not assume an image always comes back.
    /// `height` resizes server-side (query key is `height`, not the `h` a couple of PWA call sites
    /// use - those are silently ignored by the server and serve full size).
    static func snapshot(camera: String, height: Int? = nil) -> Endpoint {
        var query: [URLQueryItem] = []
        if let height {
            query.append(URLQueryItem(name: "height", value: String(height)))
        }
        return Endpoint(path: "\(camera)/latest.jpg", query: query)
    }
}
