import Foundation

/// Persists the `ServerConfig` as JSON in the App-Group `UserDefaults` suite (shareable with the
/// future Notification Service Extension). Non-secret only - the password stays in the Keychain.
struct ServerConfigStore {
    static let appGroupSuite = "group.com.sagarp.Frigate"
    private static let key = "serverConfig"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    init(suiteName: String = appGroupSuite) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func load() -> ServerConfig? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: data)
    }

    func save(_ config: ServerConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
