import Foundation

/// Normalizes a user-typed server address into a validated base `URL`. Pure and unit-testable;
/// C1's `FrigateClient` takes an already-valid `URL`, this is where raw input becomes one.
enum ServerURL {
    static func normalize(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { throw APIError.invalidURL }

        // Frigate's authenticated proxy port (8971) is TLS, so default to https when no scheme.
        if !text.contains("://") {
            text = "https://" + text
        }

        guard let components = URLComponents(string: text),
              let host = components.host, !host.isEmpty,
              let url = components.url
        else {
            throw APIError.invalidURL
        }
        return url
    }
}

extension URL {
    /// Same URL with a different scheme, used for the http:// auto-fallback. Returns nil if the
    /// URL can't be decomposed.
    func withScheme(_ scheme: String) -> URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = scheme
        return components.url
    }
}
