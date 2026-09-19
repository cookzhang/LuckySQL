import Foundation
import Security

protocol PasswordStoring {
    func save(_ password: String, for profileID: UUID) throws
    func password(for profileID: UUID) throws -> String?
    func deletePassword(for profileID: UUID) throws
}

final class KeychainStore: PasswordStoring {
    private let service = "app.luckysql.connection-password"

    func save(_ password: String, for profileID: UUID) throws {
        try deletePassword(for: profileID)
        guard !password.isEmpty else { return }
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
