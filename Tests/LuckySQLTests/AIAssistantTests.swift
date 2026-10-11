import AppKit
import SwiftUI
import XCTest
@testable import LuckySQL

@MainActor final class AIAssistantTests: XCTestCase {
    private let answer = #"{"sql":"SELECT `id` FROM `shop`.`orders` LIMIT 100;","explanation":"查询订单编号。","assumptions":["仅查看前100行"]}"#

    func testContextContainsSchemaButNeverCredentialsOrPreviewRows() async throws {
        let fixture = try await makeFixture(); defer { fixture.cleanUp() }
        fixture.model.sql = "SELECT 'private-literal' FROM orders;"
        let session = fixture.model.aiAssistant.session(for: fixture.model.activeTabID)
        session.includeSQL = false
        let context = try await fixture.model.prepareAIContext(action: .generate)
        let sent = try context.promptData(action: .generate, prompt: "列出订单")
        XCTAssertEqual(context.tableNames, ["shop.orders"])
        XCTAssertEqual(context.serverVersion, "5.7.44")
        XCTAssertTrue(sent.contains("datetime"))
        for privateValue in ["database-password", "fixture-api-key", "private-literal", "private-preview-value", fixture.model.connectedProfileID!.uuidString] {
            XCTAssertFalse(sent.contains(privateValue), privateValue)
        }
        XCTAssertEqual(context.sourceSQL, "")
    }

    func testCompletedSuggestionOpensDraftWithoutExecutingSQL() async throws {
        let fixture = try await makeFixture(); defer { fixture.cleanUp() }
        let oldTab = fixture.model.activeTabID, oldSQL = fixture.model.sql
        fixture.model.startAIAssistance(action: .generate, prompt: "列出订单", includeSQL: false)
        let session = fixture.model.aiAssistant.session(for: oldTab)
        try await settle(session)
        let suggestion = try XCTUnwrap(session.suggestion)
        let before = await fixture.server.queries
        XCTAssertTrue(fixture.model.applyAISuggestion(suggestion, replacingSelection: false))
        let after = await fixture.server.queries
        XCTAssertEqual(before, after)
        XCTAssertNotEqual(fixture.model.activeTabID, oldTab)
        XCTAssertEqual(fixture.model.queryTabs.first(where: { $0.id == oldTab })?.sql, oldSQL)
        XCTAssertEqual(fixture.model.sql, suggestion.sql)
        XCTAssertFalse(fixture.model.isRunning)
    }

    func testChangingDraftEvenBackToOriginalInvalidatesSuggestion() async throws {
        let fixture = try await makeFixture(); defer { fixture.cleanUp() }
        let context = try await fixture.model.prepareAIContext(action: .generate)
        let suggestion = try AISuggestion.parse(answer, source: context)
        let original = fixture.model.sql
        fixture.model.sql = original + "\n-- changed"
        fixture.model.sql = original
        XCTAssertFalse(fixture.model.isAISuggestionCurrent(suggestion))
        XCTAssertFalse(fixture.model.applyAISuggestion(suggestion, replacingSelection: true))
        XCTAssertFalse(fixture.model.applyAISuggestion(suggestion, replacingSelection: false))
        XCTAssertEqual(fixture.model.sql, original)
    }

    func testReplyStaysWithOriginalTabAndClosingTabCancelsItsSession() async throws {
        let fixture = try await makeFixture(delay: .milliseconds(80)); defer { fixture.cleanUp() }
        let original = fixture.model.activeTabID
        fixture.model.startAIAssistance(action: .generate, prompt: "列出订单", includeSQL: false)
        let session = fixture.model.aiAssistant.session(for: original)
        fixture.model.newQuery(sql: "SELECT 2;")
        // The request either captures the original tab, or safely declines before starting.
        try await settle(session)
        XCTAssertEqual(fixture.model.sql, "SELECT 2;")
        XCTAssertNil(fixture.model.aiAssistant.session(for: fixture.model.activeTabID).suggestion)
        if let suggestion = session.suggestion {
            XCTAssertEqual(suggestion.source.tabID, original)
            XCTAssertFalse(fixture.model.isAISuggestionCurrent(suggestion))
        }
        fixture.model.closeTab(original)
        XCTAssertNil(fixture.model.aiAssistant.sessions[original])
    }

    func testCanonicallyEqualUnicodeEditInvalidatesCapturedSQLRange() async throws {
        let fixture = try await makeFixture(); defer { fixture.cleanUp() }
        let original = "SELECT 'é' FROM orders;", edited = "SELECT 'e\u{301}' FROM orders;"
        XCTAssertEqual(original, edited)
        XCTAssertNotEqual(original.utf16.count, edited.utf16.count)
        fixture.model.sql = original
        fixture.model.aiAssistant.session(for: fixture.model.activeTabID).includeSQL = true
        let context = try await fixture.model.prepareAIContext(action: .generate)
        let suggestion = try AISuggestion.parse(answer, source: context)
        fixture.model.sql = edited
        let changedContext = try await fixture.model.prepareAIContext(action: .generate)
        XCTAssertFalse(changedContext.hasSameConversationScope(as: context))
        XCTAssertFalse(fixture.model.isAISuggestionCurrent(suggestion))
        XCTAssertFalse(fixture.model.applyAISuggestion(suggestion, replacingSelection: true))
        XCTAssertTrue((fixture.model.sql as NSString).isEqual(to: edited))
        fixture.model.selectedDatabase = "café"
        let databaseContext = try await fixture.model.prepareAIContext(action: .generate)
        let databaseSuggestion = try AISuggestion.parse(answer, source: databaseContext)
        XCTAssertTrue(fixture.model.isAISuggestionCurrent(databaseSuggestion))
        fixture.model.selectedDatabase = "cafe\u{301}"
        XCTAssertFalse(fixture.model.isAISuggestionCurrent(databaseSuggestion))
    }

    func testCancelPartialResponseCannotBecomeApplicableOrCancelSQL() async throws {
        let fixture = try await makeFixture(delay: .seconds(5)); defer { fixture.cleanUp() }
        let id = fixture.model.activeTabID, original = fixture.model.sql
        fixture.model.startAIAssistance(action: .generate, prompt: "列出订单", includeSQL: false)
        let session = fixture.model.aiAssistant.session(for: id)
        try await waitUntil { await fixture.recorder.count > 0 }
        fixture.model.aiAssistant.cancel(tabID: id)
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.suggestion)
        XCTAssertEqual(fixture.model.sql, original)
        let cancellations = await fixture.server.cancellations
        XCTAssertEqual(cancellations, 0)
    }

    func testRepairUsesFailedStatementAndErrorRatherThanEditedDraft() async throws {
        let fixture = try await makeFixture(); defer { fixture.cleanUp() }
        fixture.model.sql = "SELECT missing FROM orders;"
        fixture.model.runCurrentQuery()
        try await waitUntil { !fixture.model.isRunning }
        let failure = try XCTUnwrap(fixture.model.failedQueryForAI())
        XCTAssertEqual(failure.sql, "SELECT missing FROM orders;")
        fixture.model.sql = "SELECT id FROM orders;"
        fixture.model.aiAssistant.session(for: fixture.model.activeTabID).includeSQL = true
        let context = try await fixture.model.prepareAIContext(action: .repair)
        XCTAssertEqual(context.sourceSQL, failure.sql)
        XCTAssertEqual(context.queryError, "Unknown column 'missing'")
        let suggestion = try AISuggestion.parse(answer, source: context)
        XCTAssertFalse(fixture.model.isAISuggestionCurrent(suggestion))
    }

    func testConnectionChangeAndSQLExecutionInvalidateOldContext() async throws {
        let fixture = try await makeFixture(); defer { fixture.cleanUp() }
        let context = try await fixture.model.prepareAIContext(action: .generate)
        let suggestion = try AISuggestion.parse(answer, source: context)
        fixture.model.runCurrentQuery()
        try await waitUntil { !fixture.model.isRunning }
        XCTAssertFalse(fixture.model.isAISuggestionCurrent(suggestion))
        fixture.model.disconnect()
        XCTAssertFalse(fixture.model.applyAISuggestion(suggestion, replacingSelection: false))
    }

    func testNativeReplacementIsOneUndoableEditAndNeverRuns() async throws {
        let fixture = try await makeFixture(); defer { fixture.cleanUp() }
        let model = fixture.model, id = model.activeTabID, original = model.sql
        model.sqlSelection = NSRange(location: 0, length: (original as NSString).length)
        model.aiAssistant.session(for: id).includeSQL = true
        let context = try await model.prepareAIContext(action: .generate)
        let suggestion = try AISuggestion.parse(answer, source: context)
        let wrapper = SQLTextEditor(text: Binding(get: { model.sql }, set: { model.sql = $0 }),
            selection: Binding(get: { model.sqlSelection }, set: { model.sqlSelection = $0 }),
            documentID: id.uuidString, sessions: model.editorSessions)
        let host = NSHostingView(rootView: wrapper.frame(width: 600, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(model.editorSessions.views[id.uuidString]?.documentView as? CodeTextView)
        editor.undoManager?.groupsByEvent = false
        let before = await fixture.server.queries
        XCTAssertTrue(model.applyAISuggestion(suggestion, replacingSelection: true))
        XCTAssertEqual(model.sql, suggestion.sql)
        XCTAssertEqual(editor.string, suggestion.sql)
        editor.undoManager?.undo()
        XCTAssertEqual(model.sql, original)
        XCTAssertEqual(editor.string, original)
        let after = await fixture.server.queries
        XCTAssertEqual(before, after)
    }

    func testInvalidOrFencedRepliesAndWriteWarning() async throws {
        let fixture = try await makeFixture(); defer { fixture.cleanUp() }
        let context = try await fixture.model.prepareAIContext(action: .generate)
        XCTAssertThrowsError(try AISuggestion.parse("SELECT 1", source: context))
        XCTAssertThrowsError(try AISuggestion.parse(#"{"sql":"SELECT 1"}"#, source: context))
        XCTAssertNotNil(try AISuggestion.parse("```json\n" + answer + "\n```", source: context).sql)
        let write = try AISuggestion.parse(#"{"sql":"DELETE FROM orders;","explanation":"Review this write.","assumptions":[]}"#, source: context)
        XCTAssertFalse(write.warnings.isEmpty)
    }

    func testForegroundWorkStopsOnlyUnfinishedAIContextGathering() async throws {
        let fixture = try await makeFixture(); defer { fixture.cleanUp() }
        let id = fixture.model.activeTabID
        let context = try await fixture.model.prepareAIContext(action: .generate)
        fixture.model.aiAssistant.start(tabID: id, action: .generate, prompt: "List orders") {
            try await Task.sleep(for: .seconds(5))
            return context
        }
        fixture.model.runCurrentQuery()
        try await waitUntil { !fixture.model.isRunning }
        let session = fixture.model.aiAssistant.session(for: id)
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.suggestion)
        let requests = await fixture.recorder.count
        let cancellations = await fixture.server.cancellations
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(cancellations, 0)
    }

    func testAIAssistantKeepsEditorAndResultsVisibleAtMinimumWindowWidth() async throws {
        let fixture = try await makeFixture(); defer { fixture.cleanUp() }
        fixture.model.runCurrentQuery()
        try await waitUntil { !fixture.model.isRunning }
        fixture.model.showAIAssistant = true
        let size = NSSize(width: 659, height: 490)
        let host = NSHostingView(rootView: QueryWorkspaceView().environmentObject(fixture.model)
            .defaultAppStorage(fixture.defaults).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let editor = try XCTUnwrap(descendants(CodeTextView.self, in: host).first)
        let grid = try XCTUnwrap(descendants(CopyableTableView.self, in: host).first)
        XCTAssertGreaterThan(editor.visibleRect.width, 250)
        XCTAssertGreaterThan(editor.visibleRect.height, 50)
        XCTAssertGreaterThan(grid.visibleRect.width, 250)
        XCTAssertGreaterThan(grid.visibleRect.height, 100)
        XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1)
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func makeFixture(delay: Duration = .zero) async throws -> AITestFixture {
        let name = "AIAssistantTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = AITestSecrets(), store = AIConfigurationStore(defaults: defaults, keychain: keychain)
        var configuration = AIConfiguration.defaults(for: .openAI); configuration.model = "fixture-model"
        try await store.save(configuration, apiKey: "fixture-api-key")
        let recorder = AITestRecorder(), provider = AITestProvider(answer: answer, delay: delay, recorder: recorder)
        let assistant = AIAssistantModel(provider: provider, configurationStore: store)
        let server = AITestSession(), profiles = ProfileStore(defaults: defaults)
        profiles.save([ConnectionProfile(name: "Fixture", host: "127.0.0.1", database: "shop")])
        let model = AppModel(profileStore: profiles, keychain: keychain, driver: AITestDriver(server: server),
                             workspaceStore: WorkspaceStore(defaults: defaults), aiAssistant: assistant)
        model.password = "database-password"; model.connect()
        try await waitUntil { !model.isRunning }
        XCTAssertTrue(model.isConnected)
        model.selectedDatabase = "shop"; model.selectedTable = DatabaseTable(schema: "shop", name: "orders")
        model.sql = "SELECT id FROM orders;"
        return AITestFixture(name: name, defaults: defaults, model: model, server: server, recorder: recorder)
    }
    private func settle(_ session: AIAssistantSession) async throws { try await waitUntil { !session.isRunning } }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw AIAssistanceError("Fixture timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor private struct AITestFixture {
    let name: String; let defaults: UserDefaults; let model: AppModel
    let server: AITestSession; let recorder: AITestRecorder
    func cleanUp() { model.disconnect(); model.flushWorkspace(); defaults.removePersistentDomain(forName: name) }
}
private actor AITestSecrets: PasswordStoring {
    var keys: [UUID: String] = [:]
    func password(for profileID: UUID) -> String? { keys[profileID] }
    func save(_ password: String, for profileID: UUID) { keys[profileID] = password }
    func deletePassword(for profileID: UUID) { keys.removeValue(forKey: profileID) }
}
private actor AITestRecorder {
    var requests: [AIProviderRequest] = []
    var count: Int { requests.count }
    func add(_ request: AIProviderRequest) { requests.append(request) }
}
private struct AITestProvider: AIProviding {
    let answer: String; let delay: Duration; let recorder: AITestRecorder
    func stream(_ request: AIProviderRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await recorder.add(request)
                do {
                    let split = answer.index(answer.startIndex, offsetBy: 12)
                    continuation.yield(String(answer[..<split]))
                    if delay != .zero { try await Task.sleep(for: delay) }
                    try Task.checkCancellation()
                    continuation.yield(String(answer[split...])); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
private struct AITestDriver: DatabaseDriver {
    let server: AITestSession
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession { server }
}
private actor AITestSession: DatabaseSession {
    var queries: [String] = []; var cancellations = 0
    func query(_ sql: String) throws -> QueryResult {
        queries.append(sql)
        if sql.contains("missing") { throw AIAssistanceError("Unknown column 'missing'") }
        if sql.contains("@@session.sql_mode") {
            return QueryResult(columns: ["version", "sql_mode", "time_zone"], rows: [["5.7.44", "STRICT_TRANS_TABLES", "+08:00"]], elapsed: .zero, message: "")
        }
        return QueryResult(columns: ["id"], rows: [["private-preview-value"]], elapsed: .zero, message: "")
    }
    func schemas() -> [String] { ["shop"] }
    func tables(in schema: String) -> [String] { ["orders"] }
    func columns(in table: DatabaseTable) -> [LuckySQL.TableColumn] {
        [LuckySQL.TableColumn(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true, defaultValue: nil, extra: ""),
         LuckySQL.TableColumn(name: "paid_at", dataType: "datetime", isNullable: true, isPrimaryKey: false, defaultValue: nil, extra: "")]
    }
    func close() {}
    func cancelQuery() { cancellations += 1 }
}
