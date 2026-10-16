import Foundation
import XCTest
@testable import LuckySQL

@MainActor final class AITableResolutionIntegrationTests: XCTestCase {
    func testBareTableAnswerLoadsCommentsAndContinuesOriginalQuestion() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        let model = fixture.model, original = "统计最近三十天有效记录数量"
        model.startAIAssistance(action: .generate, prompt: original, includeSQL: false)
        let session = model.aiAssistant.session(for: model.activeTabID)
        try await wait { !session.isRunning }
        XCTAssertNil(session.suggestion?.sql)
        XCTAssertTrue(session.suggestion?.explanation.contains("哪张表") == true)

        model.startAIAssistance(action: .generate, prompt: "fact_case", includeSQL: false)
        try await wait { !session.isRunning }
        let requests = fixture.provider.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].messages.first?.content, original)
        XCTAssertTrue(requests[1].messages[1].content.contains("哪张表"))
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(requests[1].messages.last!.content.utf8)) as? [String: Any])
        XCTAssertEqual(payload["request"] as? String, "fact_case")
        let tables = try XCTUnwrap(payload["selected_schema_metadata"] as? [[String: Any]])
        let target = try XCTUnwrap(tables.first { $0["table"] as? String == "shop.fact_case" })
        XCTAssertEqual(target["comment"] as? String, "工单事实存档，按创建日期统计")
        let columns = try XCTUnwrap(target["columns"] as? [[String: Any]])
        let status = try XCTUnwrap(columns.first { $0["name"] as? String == "status" })
        XCTAssertEqual(status["comment"] as? String, ResolutionSession.statusDescription)
        XCTAssertTrue(session.suggestion?.sql?.contains("`status` = 1") == true)
        XCTAssertFalse(model.isRunning)
        let queries = await fixture.server.queries
        XCTAssertTrue(queries.allSatisfy { $0.contains("@@session.sql_mode") })
        XCTAssertFalse(requests[1].messages.last!.content.contains("row-data-must-not-be-sent"))
    }

    func testReadableColumnDescriptionsSurviveUnavailableFullStructure() async throws {
        let fixture = try await fixture(denyStructure: true); defer { fixture.close() }
        fixture.model.selectedTable = DatabaseTable(schema: "shop", name: "fact_case")
        let snapshot = try await fixture.model.prepareAIContext(action: .generate, prompt: "fact_case")
        let tables = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(snapshot.schemaMetadata.utf8)) as? [[String: Any]])
        let target = try XCTUnwrap(tables.first { $0["table"] as? String == "shop.fact_case" })
        let columns = try XCTUnwrap(target["columns"] as? [[String: Any]])
        XCTAssertEqual(columns.first { $0["name"] as? String == "status" }?["comment"] as? String, ResolutionSession.statusDescription)
        XCTAssertEqual(target["comment"] as? String, "工单事实存档，按创建日期统计")
    }

    func testRepairKeepsPreviouslyConfirmedTableOnThirdTurn() async throws {
        let fixture = try await fixture(); defer { fixture.close() }
        fixture.model.sql = "SELECT missing_column FROM seed;"
        fixture.model.runCurrentQuery()
        try await wait { !fixture.model.isRunning }
        XCTAssertNotNil(fixture.model.failedQueryForAI())
        let session = fixture.model.aiAssistant.session(for: fixture.model.activeTabID)
        for prompt in ["修复这个查询", "fact_case", "有效状态按字段说明处理"] {
            fixture.model.startAIAssistance(action: .repair, prompt: prompt, includeSQL: true)
            try await wait { !session.isRunning }
        }
        let request = try XCTUnwrap(fixture.provider.requests.last)
        XCTAssertEqual(fixture.provider.requests.count, 3)
        XCTAssertEqual(request.messages.first?.content, "修复这个查询")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(request.messages.last!.content.utf8)) as? [String: Any])
        let tables = try XCTUnwrap(payload["selected_schema_metadata"] as? [[String: Any]])
        XCTAssertTrue(tables.contains { $0["table"] as? String == "shop.fact_case" })
        XCTAssertEqual(payload["query_error"] as? String, "Unknown column missing_column")
    }

    private func fixture(denyStructure: Bool = false) async throws -> ResolutionFixture {
        let suite = "AITableResolution.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let secrets = ResolutionSecrets(), configuration = AIConfigurationStore(defaults: defaults, keychain: secrets)
        var settings = AIConfiguration.defaults(for: .openAI); settings.model = "fixture-model"
        try await configuration.save(settings, apiKey: "fixture-key")
        let provider = ResolutionProvider(), assistant = AIAssistantModel(provider: provider, configurationStore: configuration)
        let server = ResolutionSession(denyStructure: denyStructure), profiles = ProfileStore(defaults: defaults)
        profiles.save([ConnectionProfile(name: "Fixture", host: "fixture.invalid", database: "shop")])
        let model = AppModel(profileStore: profiles, keychain: secrets, driver: ResolutionDriver(server: server),
                             workspaceStore: WorkspaceStore(defaults: defaults), aiAssistant: assistant)
        model.connect(); try await wait { model.isConnected && !model.isRunning }
        model.selectedDatabase = "shop"; model.selectedTable = DatabaseTable(schema: "shop", name: "seed")
        return ResolutionFixture(suite: suite, defaults: defaults, model: model, provider: provider, server: server)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < end else { throw AIAssistanceError("Resolution fixture timed out.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor private struct ResolutionFixture {
    let suite: String; let defaults: UserDefaults; let model: AppModel
    let provider: ResolutionProvider; let server: ResolutionSession
    func close() { model.disconnect(); model.flushWorkspace(); defaults.removePersistentDomain(forName: suite) }
}
private actor ResolutionSecrets: PasswordStoring {
    private var keys: [UUID: String] = [:]
    func save(_ password: String, for profileID: UUID) { keys[profileID] = password }
    func password(for profileID: UUID) -> String? { keys[profileID] }
    func deletePassword(for profileID: UUID) { keys.removeValue(forKey: profileID) }
}
private struct ResolutionDriver: DatabaseDriver {
    let server: ResolutionSession
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession { server }
}
private actor ResolutionSession: DatabaseSession {
    static let statusDescription = String(repeating: "字段业务补充说明；", count: 60) + "状态口径：0=待审核，1=有效，2=作废。"
    let denyStructure: Bool
    private(set) var queries: [String] = []
    init(denyStructure: Bool) { self.denyStructure = denyStructure }
    func query(_ sql: String) throws -> QueryResult {
        queries.append(sql)
        if sql.contains("missing_column") { throw AIAssistanceError("Unknown column missing_column") }
        return QueryResult(columns: ["version", "sql_mode", "time_zone"], rows: [["8.0.36", "", "+08:00"]], elapsed: .zero, message: "")
    }
    func schemas() -> [String] { ["shop"] }
    func tables(in schema: String) -> [String] { ["seed", "fact_case"] + (0..<10).map { "dimension_\($0)" } }
    func tableSummaries(in schema: String) -> [DatabaseTableSummary] {
        tables(in: schema).map { DatabaseTableSummary(table: DatabaseTable(schema: schema, name: $0),
            comment: $0 == "fact_case" ? "工单事实存档，按创建日期统计" : "") }
    }
    func columns(in table: DatabaseTable) -> [TableColumn] {
        [TableColumn(name: "status", dataType: "int", isNullable: false, isPrimaryKey: false, defaultValue: "row-data-must-not-be-sent",
                     extra: "", comment: Self.statusDescription),
         TableColumn(name: "created_at", dataType: "datetime", isNullable: false, isPrimaryKey: false, defaultValue: nil,
                     extra: "", comment: "工单创建时间，业务时区东八区")]
    }
    func structure(in table: DatabaseTable) throws -> TableStructure {
        if denyStructure { throw AIAssistanceError("Index metadata access denied") }
        return TableStructure(columns: columns(in: table), comment: table.name == "fact_case" ? "工单事实存档，按创建日期统计" : "")
    }
    func close() {}
}
private final class ResolutionProvider: AIProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AIProviderRequest] = []
    var requests: [AIProviderRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func stream(_ request: AIProviderRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock(); let index = recorded.count; recorded.append(request); lock.unlock()
        return AsyncThrowingStream { continuation in
            let reply: [String: Any] = index == 0
                ? ["sql": NSNull(), "explanation": "有效记录基于哪张表？请回复真实表名。", "assumptions": []]
                : ["sql": "SELECT COUNT(*) FROM `shop`.`fact_case` WHERE `status` = 1 AND `created_at` >= CURRENT_TIMESTAMP - INTERVAL 30 DAY LIMIT 100;",
                   "explanation": "延续原始统计要求，使用字段说明中的有效状态。", "assumptions": []]
            let data = try! JSONSerialization.data(withJSONObject: reply)
            continuation.yield(String(decoding: data, as: UTF8.self)); continuation.finish()
        }
    }
}
