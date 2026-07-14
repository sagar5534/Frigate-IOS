import Foundation
import Security

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData
}

/// `SecItem`-backed `CredentialStoring`. Items live in a shared access group so the app and the
/// future Notification Service Extension can both read them. Accessible after first unlock (the NSE
/// runs while locked) and never synced to iCloud.
struct KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let accessGroup: String?

    /// Reserved account for the single token mirror slot. Real password accounts are
    /// `<baseURL>|<username>` (always scheme-prefixed), so this can't collide with one.
    private static let tokenAccount = "__frigate_current_token__"

    init(service: String = "com.sagarp.Frigate", accessGroup: String? = "group.com.sagarp.Frigate") {
        self.service = service
        self.accessGroup = accessGroup
    }

    func savePassword(_ password: String, account: String) throws {
        try upsert(account: account, value: password)
    }

    func password(account: String) throws -> String? {
        try read(account: account)
    }

    func saveToken(_ token: String) throws {
        try upsert(account: Self.tokenAccount, value: token)
    }

    func token() throws -> String? {
        try read(account: Self.tokenAccount)
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: SecItem plumbing

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func upsert(account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.invalidData }

        var query = baseQuery()
        query[kSecAttrAccount as String] = account

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    private func read(account: String) throws -> String? {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
