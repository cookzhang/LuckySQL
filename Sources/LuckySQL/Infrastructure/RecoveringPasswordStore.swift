import Foundation
import Security

/// Rotates inaccessible ad-hoc signing identities without changing old ACLs.
/// Defaults contains only opaque record identifiers, never credentials.
actor RecoveringPasswordStore: PasswordStoring {
    private let store: any PasswordStoring
    private let defaults: UserDefaults
    init(store: any PasswordStoring = KeychainStore(), defaults: UserDefaults? = nil) {
        self.store = store; self.defaults = defaults ?? .standard
    }
    private func key(_ id: UUID) -> String { "passwordRecord.\(id.uuidString)" }
    private func record(_ id: UUID) -> UUID {
        defaults.string(forKey: key(id)).flatMap(UUID.init(uuidString:)) ?? id
    }
    func password(for profileID: UUID) async throws -> String? {
        try await store.password(for: record(profileID))
    }
    func save(_ password: String, for profileID: UUID) async throws {
        guard !password.isEmpty else { try await deletePassword(for: profileID); return }
        do {
            // Keychain can permit an update while the old ACL still denies a
            // read to the current signing identity. Probe before updating so a
            // successful write is not mistaken for usable saved credentials.
            _ = try await store.password(for: record(profileID))
            try await store.save(password, for: record(profileID))
        }
        catch let error as KeychainError where error.status == errSecInteractionNotAllowed || error.status == errSecAuthFailed {
            let replacement = UUID()
            try await store.save(password, for: replacement)
            guard try await store.password(for: replacement) == password else { throw KeychainError(errSecAuthFailed) }
            defaults.set(replacement.uuidString, forKey: key(profileID))
        }
    }
    func deletePassword(for profileID: UUID) async throws {
        try await store.deletePassword(for: record(profileID))
        defaults.removeObject(forKey: key(profileID))
    }
}
