import Foundation
import Security
import XCTest
@testable import LuckySQL

final class AIConfigurationTests: XCTestCase {
    func testEndpointNormalizationAndProtocolPaths() throws {
        var configuration = AIConfiguration.defaults(for: .openAI)
        for input in ["https://api.openai.com", " https://API.OPENAI.COM:443/v1/ ", "https://api.openai.com/v1/chat/completions/"] {
            configuration.baseURL = input
            XCTAssertEqual(try configuration.endpointURL().absoluteString, "https://api.openai.com/v1/chat/completions")
        }
        configuration.baseURL = "http://127.0.0.1:11434/v1"
        XCTAssertEqual(try configuration.endpointURL().absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        configuration.baseURL = "http://localhost:8080/proxy/v1"
        XCTAssertEqual(try configuration.endpointURL().absoluteString, "http://localhost:8080/proxy/v1/chat/completions")
        configuration = .defaults(for: .anthropic)
        XCTAssertEqual(try configuration.endpointURL().absoluteString, "https://api.anthropic.com/v1/messages")
        configuration.baseURL = "http://[::1]:8080/v1/messages"
        XCTAssertEqual(try configuration.endpointURL().absoluteString, "http://[::1]:8080/v1/messages")
    }

    func testURLValidationRejectsUnsafeOrAmbiguousDestinations() {
        var configuration = AIConfiguration.defaults(for: .openAI)
        for input in ["http://api.example.com/v1", "ftp://localhost/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=value", "https://example.com/v1#fragment", "https:///v1", "https://example.com:0/v1", "https://example.com:65536/v1", "https://exam ple.com/v1", "http://127.0.0.1.evil.example/v1", "https://example.com/v1/messages"] {
            configuration.baseURL = input
            XCTAssertThrowsError(try configuration.endpointURL(), input)
        }
    }

    func testCompleteRootEndpointsRemainUnchangedAfterValidationForBothProtocols() throws {
        for (kind, path) in [(AIProtocol.openAI, "/chat/completions"), (AIProtocol.anthropic, "/messages")] {
            for prefix in ["https://gateway.example", "https://gateway.example/", "https://gateway.example/proxy/"] {
                var configuration = AIConfiguration.defaults(for: kind)
                configuration.baseURL = prefix + path
                configuration.model = "test-model"
                let originalEndpoint = try configuration.endpointURL()
                let validated = try configuration.validated()
                XCTAssertEqual(try validated.endpointURL(), originalEndpoint)
                XCTAssertEqual(validated.baseURL, originalEndpoint.absoluteString)
                XCTAssertEqual(try validated.validated(), validated)
            }
        }
    }

    func testModelAndAPIKeyValidation() throws {
        var configuration = AIConfiguration.defaults(for: .openAI)
        XCTAssertThrowsError(try configuration.validated())
        configuration.model = " model-from-my-provider "
        XCTAssertEqual(try configuration.validated().model, "model-from-my-provider")
        configuration.model = "model\nheader"
        XCTAssertThrowsError(try configuration.validated())
        XCTAssertThrowsError(try AIConfigurationStore.validatedAPIKey(" "))
        XCTAssertThrowsError(try AIConfigurationStore.validatedAPIKey("key\nsecret"))
    }

    @MainActor func testMetadataPersistenceExcludesSecretAndProtocolsStayIndependent() async throws {
        let name = "AIConfiguration.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = AIConfigurationPasswords()
        let store = AIConfigurationStore(defaults: defaults, keychain: backend)
        var openAI = store.configuration(for: .openAI); openAI.model = "openai-test-model"
        var anthropic = store.configuration(for: .anthropic); anthropic.model = "anthropic-test-model"
        anthropic.baseURL = "https://anthropic.example.com/proxy/v1"
        try await store.saveDrafts([openAI, anthropic], apiKeys: [.openAI: "unique-openai-secret", .anthropic: "unique-anthropic-secret"], selectedProtocol: .anthropic)
        let persisted = try XCTUnwrap(defaults.data(forKey: AIConfigurationStore.persistenceKey))
        let text = try XCTUnwrap(String(data: persisted, encoding: .utf8))
        XCTAssertFalse(text.contains("unique-openai-secret")); XCTAssertFalse(text.contains("unique-anthropic-secret"))
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: name)).contains("unique-openai-secret"))
        let reloaded = AIConfigurationStore(defaults: defaults, keychain: backend)
        XCTAssertEqual(reloaded.configuration.protocolKind, .anthropic)
        XCTAssertEqual(reloaded.configuration(for: .openAI).model, "openai-test-model")
        XCTAssertEqual(reloaded.configuration(for: .anthropic).baseURL, "https://anthropic.example.com/proxy/v1")
        let openKey = try await reloaded.loadAPIKey(for: reloaded.configuration(for: .openAI))
        let anthropicCredentials = try await reloaded.credentials()
        XCTAssertEqual(openKey, "unique-openai-secret")
        XCTAssertEqual(anthropicCredentials.apiKey, "unique-anthropic-secret")
        XCTAssertNotEqual(reloaded.configuration(for: .openAI).apiKeyRecordID, reloaded.configuration(for: .anthropic).apiKeyRecordID)
    }

    @MainActor func testChangedEndpointCannotInheritSavedKey() async throws {
        let name = "AIConfiguration.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = AIConfigurationPasswords(), store = AIConfigurationStore(defaults: defaults, keychain: backend)
        var configuration = store.configuration; configuration.model = "test-model"
        try await store.save(configuration, apiKey: "old-endpoint-key")
        let old = store.configuration
        var changed = old; changed.baseURL = "https://different.example.com/v1"
        let inherited = try await store.loadAPIKey(for: changed)
        XCTAssertNil(inherited)
        try await store.save(changed, apiKey: "new-endpoint-key")
        XCTAssertNotEqual(store.configuration.apiKeyRecordID, old.apiKeyRecordID)
        let credentials = try await store.credentials()
        XCTAssertEqual(credentials.apiKey, "new-endpoint-key")
        let oldKey = try await backend.password(for: old.apiKeyRecordID)
        XCTAssertEqual(oldKey, "old-endpoint-key")
    }

    @MainActor func testKeychainFailureKeepsSessionUsableWithoutPersistingSecret() async throws {
        let name = "AIConfiguration.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = AIConfigurationPasswords(); await backend.setUnavailable(true)
        let store = AIConfigurationStore(defaults: defaults, keychain: backend)
        var configuration = store.configuration; configuration.model = "test-model"
        let notice = try await store.save(configuration, apiKey: "session-only-unique-secret")
        XCTAssertNotNil(notice); XCTAssertNotNil(store.storageNotice)
        let credentials = try await store.credentials()
        XCTAssertEqual(credentials.apiKey, "session-only-unique-secret")
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: name)).contains("session-only-unique-secret"))
        let restarted = AIConfigurationStore(defaults: defaults, keychain: backend)
        do { _ = try await restarted.credentials(); XCTFail("Session-only key must not survive restarting") }
        catch { XCTAssertEqual(error as? AIConfigurationError, .keyUnavailable) }
    }

    @MainActor func testInvalidConfigurationDoesNotChangeSavedMetadataOrKeys() async throws {
        let name = "AIConfiguration.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = AIConfigurationPasswords(), store = AIConfigurationStore(defaults: defaults, keychain: backend)
        let original = store.configuration
        var invalid = original; invalid.baseURL = "http://remote.example.com/v1"; invalid.model = "test-model"
        do { try await store.save(invalid, apiKey: "unused-secret"); XCTFail("Expected validation failure") } catch {}
        XCTAssertEqual(store.configuration, original)
        XCTAssertNil(defaults.data(forKey: AIConfigurationStore.persistenceKey))
        let saved = await backend.savedCount
        XCTAssertEqual(saved, 0)
    }

    @MainActor func testLateKeyReadIsRejectedAfterEndpointChanges() async throws {
        let name = "AIConfiguration.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = AIConfigurationPasswords(), store = AIConfigurationStore(defaults: defaults, keychain: backend)
        var original = store.configuration; original.model = "test-model"
        try await store.save(original, apiKey: "original-key")
        // Recreate to avoid the deliberately retained in-memory key cache.
        let reloaded = AIConfigurationStore(defaults: defaults, keychain: backend)
        let snapshot = reloaded.configuration
        await backend.pauseNextRead()
        let load = Task { try await reloaded.loadAPIKey(for: snapshot) }
        await backend.waitUntilReadPaused()
        var changed = snapshot; changed.baseURL = "https://new.example.com/v1"
        try await reloaded.save(changed, apiKey: "new-key")
        await backend.releaseRead()
        do { _ = try await load.value; XCTFail("An old endpoint read must be rejected") }
        catch { XCTAssertEqual(error as? AIConfigurationError, .configurationChanged) }
    }

    @MainActor func testConcurrentSaveIsRejectedAndCredentialsWaitForCommittedConfiguration() async throws {
        let name = "AIConfiguration.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = AIConfigurationPasswords(), store = AIConfigurationStore(defaults: defaults, keychain: backend)
        var original = store.configuration; original.model = "original-model"
        try await store.save(original, apiKey: "original-key")
        let committed = store.configuration
        var first = committed; first.model = "first-window-model"
        var second = committed; second.model = "second-window-model"
        await backend.pauseNextSave()
        let saving = Task { try await store.save(first, apiKey: "first-window-key") }
        await backend.waitUntilSavePaused()
        do { try await store.save(second, apiKey: "second-window-key"); XCTFail("Expected a save conflict") }
        catch { XCTAssertEqual(error as? AIConfigurationError, .savingConfiguration) }
        do { _ = try await store.credentials(); XCTFail("Must not read credentials during a save") }
        catch { XCTAssertEqual(error as? AIConfigurationError, .savingConfiguration) }
        do { _ = try await store.loadAPIKey(for: committed); XCTFail("Must not read a cached key during a save") }
        catch { XCTAssertEqual(error as? AIConfigurationError, .savingConfiguration) }
        XCTAssertEqual(store.configuration, committed)
        await backend.releaseSave()
        _ = try await saving.value
        let credentials = try await store.credentials()
        XCTAssertEqual(credentials.configuration.model, "first-window-model")
        XCTAssertEqual(credentials.apiKey, "first-window-key")
        let reloaded = AIConfigurationStore(defaults: defaults, keychain: backend)
        let reloadedCredentials = try await reloaded.credentials()
        XCTAssertEqual(reloadedCredentials.configuration, credentials.configuration)
        XCTAssertEqual(reloadedCredentials.apiKey, "first-window-key")
        let writes = await backend.savedCount
        XCTAssertEqual(writes, 2, "The rejected save must not write a key")
    }

    @MainActor func testLateKeyReadIsRejectedWhenOnlyKeyChangesAtSameEndpoint() async throws {
        let name = "AIConfiguration.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = AIConfigurationPasswords(), store = AIConfigurationStore(defaults: defaults, keychain: backend)
        var configuration = store.configuration; configuration.model = "same-model"
        try await store.save(configuration, apiKey: "old-key")
        let reloaded = AIConfigurationStore(defaults: defaults, keychain: backend)
        let snapshot = reloaded.configuration
        await backend.pauseNextRead()
        let loading = Task { try await reloaded.loadAPIKey(for: snapshot) }
        await backend.waitUntilReadPaused()
        try await reloaded.save(snapshot, apiKey: "replacement-key")
        XCTAssertEqual(reloaded.configuration, snapshot, "Credential rotation need not change public metadata")
        await backend.releaseRead()
        do { _ = try await loading.value; XCTFail("Must reject a key read that predates a save") }
        catch { XCTAssertEqual(error as? AIConfigurationError, .configurationChanged) }
        let credentials = try await reloaded.credentials()
        XCTAssertEqual(credentials.apiKey, "replacement-key")
    }

    func testRecoveryUsesSeparateAIRecordNamespace() async throws {
        let name = "AIConfiguration.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = AIRotatingPasswords(), id = UUID()
        await backend.deny(id)
        let store = RecoveringPasswordStore(store: backend, defaults: defaults, keyPrefix: "aiPasswordRecord.")
        try await store.save("ai-specific-secret", for: id)
        XCTAssertNotNil(defaults.string(forKey: "aiPasswordRecord.\(id.uuidString)"))
        XCTAssertNil(defaults.string(forKey: "passwordRecord.\(id.uuidString)"))
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: name)).contains("ai-specific-secret"))
    }
}

private actor AIConfigurationPasswords: PasswordStoring {
    private var keys: [UUID: String] = [:]
    private var unavailable = false
    private var shouldPauseRead = false
    private var pausedRead: CheckedContinuation<String?, Never>?
    private var pausedValue: String?
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldPauseSave = false
    private var pausedSave: CheckedContinuation<Void, Never>?
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var savedCount = 0
    func setUnavailable(_ value: Bool) { unavailable = value }
    func pauseNextRead() { shouldPauseRead = true }
    func pauseNextSave() { shouldPauseSave = true }
    func waitUntilSavePaused() async {
        if pausedSave != nil { return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }
    func releaseSave() { pausedSave?.resume(); pausedSave = nil }
    func waitUntilReadPaused() async {
        if pausedRead != nil { return }
        await withCheckedContinuation { pausedWaiters.append($0) }
    }
    func releaseRead() { pausedRead?.resume(returning: pausedValue); pausedRead = nil; pausedValue = nil }
    func password(for profileID: UUID) async throws -> String? {
        if unavailable { throw KeychainError(errSecInteractionNotAllowed) }
        if shouldPauseRead {
            shouldPauseRead = false; pausedValue = keys[profileID]
            return await withCheckedContinuation { continuation in
                pausedRead = continuation
                for waiter in pausedWaiters { waiter.resume() }
                pausedWaiters = []
            }
        }
        return keys[profileID]
    }
    func save(_ password: String, for profileID: UUID) async throws {
        if unavailable { throw KeychainError(errSecInteractionNotAllowed) }
        if shouldPauseSave {
            shouldPauseSave = false
            await withCheckedContinuation { continuation in
                pausedSave = continuation
                for waiter in saveWaiters { waiter.resume() }
                saveWaiters = []
            }
        }
        keys[profileID] = password; savedCount += 1
    }
    func deletePassword(for profileID: UUID) { keys.removeValue(forKey: profileID) }
}

private actor AIRotatingPasswords: PasswordStoring {
    private var denied = Set<UUID>()
    private var keys: [UUID: String] = [:]
    func deny(_ id: UUID) { denied.insert(id) }
    func password(for profileID: UUID) throws -> String? {
        if denied.contains(profileID) { throw KeychainError(errSecInteractionNotAllowed) }
        return keys[profileID]
    }
    func save(_ password: String, for profileID: UUID) { keys[profileID] = password }
    func deletePassword(for profileID: UUID) { keys.removeValue(forKey: profileID) }
}
