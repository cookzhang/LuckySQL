import Foundation
import Combine

@MainActor
final class AIConfigurationStore: ObservableObject {
    static let shared = AIConfigurationStore()
    static let keychainService = "app.luckysql.ai-api-key"
    static let persistenceKey = "ai.configurations.v1"
    static let sessionOnlyMessage = "The AI API key could not be saved securely. It is available only for this app session; enter it again after restarting."

    @Published private(set) var configuration: AIConfiguration
    @Published private(set) var storageNotice: String?
    private let defaults: UserDefaults
    private let keychain: any PasswordStoring
    private var configurations: [AIProtocol: AIConfiguration]
    private var sessionKeys: [UUID: String] = [:]
    private var isSavingConfigurations = false
    private var configurationRevision: UInt64 = 0

    private struct StoredConfigurations: Codable {
        var selectedProtocol: AIProtocol
        var configurations: [AIProtocol: AIConfiguration]
    }

    init(defaults: UserDefaults = .standard, keychain: (any PasswordStoring)? = nil) {
        self.defaults = defaults
        self.keychain = keychain ?? RecoveringPasswordStore(store: KeychainStore(service: Self.keychainService),
                                                          defaults: defaults, keyPrefix: "aiPasswordRecord.")
        var entries = Dictionary(uniqueKeysWithValues: AIProtocol.allCases.map { ($0, AIConfiguration.defaults(for: $0)) })
        var selectedProtocol = AIProtocol.openAI
        if let data = defaults.data(forKey: Self.persistenceKey),
           let stored = try? JSONDecoder().decode(StoredConfigurations.self, from: data) {
            for (kind, entry) in stored.configurations where kind == entry.protocolKind && (try? entry.endpointURL()) != nil {
                entries[kind] = entry
            }
            selectedProtocol = stored.selectedProtocol
        }
        configurations = entries
        configuration = entries[selectedProtocol]!
    }

    func configuration(for protocolKind: AIProtocol) -> AIConfiguration { configurations[protocolKind]! }

    /// Only a saved endpoint and record pairing may retrieve an existing key.
    /// An edited endpoint never inherits the previous endpoint's credentials.
    func loadAPIKey(for draft: AIConfiguration) async throws -> String? {
        guard !isSavingConfigurations else { throw AIConfigurationError.savingConfiguration }
        let revision = configurationRevision
        guard let saved = configurations[draft.protocolKind], saved.apiKeyRecordID == draft.apiKeyRecordID,
              try saved.endpointURL() == draft.endpointURL() else { return nil }
        if let key = sessionKeys[saved.apiKeyRecordID] { return key }
        let key = try await keychain.password(for: saved.apiKeyRecordID)
        guard !isSavingConfigurations else { throw AIConfigurationError.savingConfiguration }
        guard configurationRevision == revision, configurations[draft.protocolKind] == saved else {
            throw AIConfigurationError.configurationChanged
        }
        return key
    }

    func credentials() async throws -> (configuration: AIConfiguration, apiKey: String) {
        guard !isSavingConfigurations else { throw AIConfigurationError.savingConfiguration }
        let revision = configurationRevision
        let saved = try configuration.validated()
        let key: String?
        do { key = try await loadAPIKey(for: saved) }
        catch let error as AIConfigurationError { throw error }
        catch { throw AIConfigurationError.keyUnavailable }
        guard !isSavingConfigurations else { throw AIConfigurationError.savingConfiguration }
        guard configurationRevision == revision,
              configuration.apiKeyRecordID == saved.apiKeyRecordID,
              configuration.protocolKind == saved.protocolKind,
              try configuration.endpointURL() == saved.endpointURL() else { throw AIConfigurationError.configurationChanged }
        guard let key else { throw AIConfigurationError.missingAPIKey }
        return (saved, try Self.validatedAPIKey(key))
    }

    @discardableResult
    func save(_ draft: AIConfiguration, apiKey: String) async throws -> String? {
        try await saveDrafts([draft], apiKeys: [draft.protocolKind: apiKey], selectedProtocol: draft.protocolKind)
    }

    /// Validate everything before storing any metadata. Keys remain only in
    /// Keychain or in process memory if secure storage is unavailable.
    @discardableResult
    func saveDrafts(_ drafts: [AIConfiguration], apiKeys: [AIProtocol: String], selectedProtocol: AIProtocol) async throws -> String? {
        // MainActor methods can reenter during Keychain awaits. Reject a second
        // save instead of interleaving key writes and metadata from two sheets.
        guard !isSavingConfigurations else { throw AIConfigurationError.savingConfiguration }
        isSavingConfigurations = true
        defer { isSavingConfigurations = false }
        var prepared: [(configuration: AIConfiguration, key: String)] = []
        for draft in drafts {
            var normalized = try draft.validated()
            let key = try Self.validatedAPIKey(apiKeys[draft.protocolKind] ?? "")
            let previous = configurations[draft.protocolKind]!
            if try previous.endpointURL() == normalized.endpointURL() {
                normalized.apiKeyRecordID = previous.apiKeyRecordID
            } else {
                normalized.apiKeyRecordID = UUID()
            }
            prepared.append((normalized, key))
        }
        guard prepared.contains(where: { $0.configuration.protocolKind == selectedProtocol }) else {
            throw AIConfigurationError.missingAPIKey
        }
        try Task.checkCancellation()
        configurationRevision &+= 1
        var committedConfigurations = configurations
        for entry in prepared { committedConfigurations[entry.configuration.protocolKind] = entry.configuration }
        let stored = StoredConfigurations(selectedProtocol: selectedProtocol, configurations: committedConfigurations)
        let encoded = try JSONEncoder().encode(stored)
        var sessionOnly = false
        for entry in prepared {
            do {
                try await keychain.save(entry.key, for: entry.configuration.apiKeyRecordID)
                guard try await keychain.password(for: entry.configuration.apiKeyRecordID) == entry.key else {
                    throw AIConfigurationError.keyUnavailable
                }
            } catch {
                sessionOnly = true
            }
            // Save may succeed while reads remain unavailable to an ad-hoc
            // signing identity. Keep the entered value usable in either case.
            sessionKeys[entry.configuration.apiKeyRecordID] = entry.key
        }
        defaults.set(encoded, forKey: Self.persistenceKey)
        configurations = committedConfigurations
        configuration = configurations[selectedProtocol]!
        storageNotice = sessionOnly ? NSLocalizedString(Self.sessionOnlyMessage, comment: "AI secure storage unavailable") : nil
        return storageNotice
    }

    nonisolated static func validatedAPIKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIConfigurationError.missingAPIKey }
        guard !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AIConfigurationError.invalidAPIKey
        }
        return key
    }
}
