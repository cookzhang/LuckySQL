import Foundation
import XCTest
@testable import LuckySQL

@MainActor
final class AIAssistantReviewTests: XCTestCase {
    func testExplainResponseCannotBecomeAnApplicableSQLSuggestion() async throws {
        let suite = "AIReviewExplain.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIConfigurationStore(defaults: defaults, keychain: AIReviewSecrets())
        var configuration = AIConfiguration.defaults(for: .openAI); configuration.model = "fixture-model"
        try await store.save(configuration, apiKey: "fixture-key")
        let provider = AIReviewReplyProvider(reply: "{\"sql\":\"DELETE FROM shop.orders;\",\"explanation\":\"Explanation\",\"assumptions\":[]}")
        let assistant = AIAssistantModel(provider: provider, configurationStore: store)
        let tabID = UUID(), context = snapshot(tabID: tabID)
        assistant.start(tabID: tabID, action: .explain, prompt: "Explain") { context }
        let session = assistant.session(for: tabID)
        try await waitFor { !session.isRunning }
        XCTAssertNil(session.suggestion?.sql, "Explain must not become a draft-changing request when the model ignores its prompt.")
    }

    func testSchemaChangeInvalidatesCompletedSuggestion() async throws {
        let suite = "AIReviewSchema.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try await connectedModel(defaults)
        defer { model.disconnect() }
        let source = try await model.prepareAIContext(action: .generate)
        let suggestion = candidate(source)
        XCTAssertTrue(model.isAISuggestionCurrent(suggestion))
        try await model.executeSchemaChange("ALTER TABLE `shop`.`orders` ADD COLUMN `name` VARCHAR(50)")
        XCTAssertFalse(model.isAISuggestionCurrent(suggestion), "A schema designer write must invalidate suggestions using the prior schema.")
    }

    func testExplicitStructureRefreshInvalidatesCompletedSuggestion() async throws {
        let suite = "AIReviewRefresh.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try await connectedModel(defaults)
        defer { model.disconnect() }
        let suggestion = candidate(try await model.prepareAIContext(action: .generate))
        XCTAssertTrue(model.isAISuggestionCurrent(suggestion))
        model.showStructure(DatabaseTable(schema: "shop", name: "orders"), force: true)
        try await waitFor { !model.isRunning }
        XCTAssertFalse(model.isAISuggestionCurrent(suggestion), "Refresh can observe external schema changes and must invalidate old metadata.")
    }

    func testChangedDocumentCannotBeReplacedByOriginalSuggestion() async throws {
        let suite = "AIReviewDraft.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try await connectedModel(defaults)
        defer { model.disconnect() }
        let suggestion = candidate(try await model.prepareAIContext(action: .generate))
        let newerSQL = "SELECT 'keep my new text';"
        model.updateSQL(newerSQL, in: model.activeTabID)
        XCTAssertFalse(model.applyAISuggestion(suggestion, replacingSelection: true))
        XCTAssertEqual(model.sql, newerSQL)
    }

    func testFailedNewScopeDoesNotReusePreviouslyIncludedSQLOnRetry() async throws {
        let suite = "AIReviewHistory.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIConfigurationStore(defaults: defaults, keychain: AIReviewSecrets())
        var configuration = AIConfiguration.defaults(for: .openAI); configuration.model = "fixture-model"
        try await store.save(configuration, apiKey: "fixture-key")
        let provider = AIReviewRecordingProvider()
        let assistant = AIAssistantModel(provider: provider, configurationStore: store)
        let tabID = UUID(), included = snapshot(tabID: tabID)
        let excluded = AIContextSnapshot(workspaceID: included.workspaceID, profileID: included.profileID,
            connectionEpoch: included.connectionEpoch, tabID: included.tabID,
            documentRevision: included.documentRevision, database: included.database,
            tableNames: included.tableNames, sourceSQL: "", selection: included.selection,
            schemaMetadata: included.schemaMetadata)
        let session = assistant.session(for: tabID)
        assistant.start(tabID: tabID, action: .generate, prompt: "First request") { included }
        try await waitFor { !session.isRunning }
        XCTAssertNotNil(session.suggestion)
        assistant.start(tabID: tabID, action: .generate, prompt: "SQL excluded") { excluded }
        try await waitFor { !session.isRunning }
        XCTAssertNotNil(session.errorMessage)
        assistant.start(tabID: tabID, action: .generate, prompt: "Retry with SQL excluded") { excluded }
        try await waitFor { !session.isRunning }
        let retry = try XCTUnwrap(provider.recordedRequests().last)
        XCTAssertEqual(provider.recordedRequests().count, 3)
        XCTAssertEqual(retry.messages.count, 1, "Failed scope changes must not attach messages from the previous SQL scope.")
        XCTAssertFalse(retry.messages.contains { $0.content.contains(included.sourceSQL) })
    }

    private func connectedModel(_ defaults: UserDefaults) async throws -> AppModel {
        let store = AIConfigurationStore(defaults: defaults, keychain: AIReviewSecrets())
        let assistant = AIAssistantModel(provider: AIReviewReplyProvider(reply: ""), configurationStore: store)
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: AIReviewSecrets(),
                             driver: AIReviewDriver(), workspaceStore: WorkspaceStore(defaults: defaults), aiAssistant: assistant)
        model.connect()
        try await waitFor { model.isConnected && !model.isRunning }
        model.selectedDatabase = "shop"
        model.selectedTable = DatabaseTable(schema: "shop", name: "orders")
        return model
    }

    private func snapshot(tabID: UUID) -> AIContextSnapshot {
        AIContextSnapshot(workspaceID: UUID(), profileID: nil, connectionEpoch: nil, tabID: tabID,
                          documentRevision: 0, database: "shop", tableNames: ["shop.orders"],
                          sourceSQL: "SELECT * FROM shop.orders;", selection: NSRange(location: 0, length: 26),
                          schemaMetadata: "[]")
    }

    private func candidate(_ source: AIContextSnapshot) -> AISuggestion {
        AISuggestion(sql: "SELECT `id` FROM `shop`.`orders` LIMIT 100;", explanation: "List orders", assumptions: [], source: source)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw AIAssistanceError("Test fixture timed out.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct AIReviewReplyProvider: AIProviding {
    let reply: String
    func stream(_ request: AIProviderRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in continuation.yield(reply); continuation.finish() }
    }
}

private final class AIReviewRecordingProvider: AIProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AIProviderRequest] = []
    func recordedRequests() -> [AIProviderRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
    func stream(_ request: AIProviderRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock(); let index = requests.count; requests.append(request); lock.unlock()
        return AsyncThrowingStream { continuation in
            if index == 1 { continuation.finish(throwing: AIAssistanceError("Fixture request failed.")); return }
            continuation.yield("{\"sql\":\"SELECT 1;\",\"explanation\":\"Fixture suggestion\",\"assumptions\":[]}")
            continuation.finish()
        }
    }
}

private actor AIReviewSecrets: PasswordStoring {
    private var keys: [UUID: String] = [:]
    func save(_ password: String, for profileID: UUID) { keys[profileID] = password }
    func password(for profileID: UUID) -> String? { keys[profileID] }
    func deletePassword(for profileID: UUID) { keys.removeValue(forKey: profileID) }
}

private struct AIReviewDriver: DatabaseDriver {
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession { AIReviewDatabaseSession() }
}

private actor AIReviewDatabaseSession: DatabaseSession {
    func query(_ sql: String) -> QueryResult {
        if sql.contains("@@session.sql_mode") {
            return QueryResult(columns: ["version", "sql_mode", "time_zone"], rows: [["8.0.36", "", "+00:00"]],
                               elapsed: .zero, message: "fixture server")
        }
        return QueryResult(columns: [], rows: [], elapsed: .zero, message: "fixture query")
    }
    func schemas() -> [String] { ["shop"] }
    func tables(in schema: String) -> [String] { ["orders"] }
    func columns(in table: DatabaseTable) -> [TableColumn] {
        [TableColumn(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true, defaultValue: nil, extra: "")]
    }
    func structure(in table: DatabaseTable) -> TableStructure { TableStructure(columns: columns(in: table)) }
    func close() {}
}
