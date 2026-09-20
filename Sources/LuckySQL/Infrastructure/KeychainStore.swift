import Foundation
import Security

protocol PasswordStoring: Sendable {
    func save(_ password: String, for profileID: UUID) async throws
    func password(for profileID: UUID) async throws -> String?
    func deletePassword(for profileID: UUID) async throws
}

actor KeychainStore: PasswordStoring {
    private let service = "app.luckysql.connection-password"

    func save(_ password: String, for profileID: UUID) throws {
        guard !password.isEmpty else { try deletePassword(for: profileID); return }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: profileID.uuidString]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: Data(password.utf8)] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(update) }
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID.uuidString,
            kSecValueData: Data(password.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status) }
    }

    func password(for profileID: UUID) throws -> String? {
        var value: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw KeychainError(status) }
        return String(data: data, encoding: .utf8)
    }

    func deletePassword(for profileID: UUID) throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profileID.uuidString
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}
