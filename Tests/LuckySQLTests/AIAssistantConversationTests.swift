import Foundation
import XCTest
@testable import LuckySQL

@MainActor
final class AIAssistantConversationTests: XCTestCase {
    func testClarificationAnswerKeepsOriginalGoalWhenTableMetadataIsAdded() async throws {
        let question = reply(sql: nil, explanation: "你说的订单是哪张表？")
        let fixture = try await fixture(replies: [.text(question), .text(reply(sql: "SELECT id FROM shop.orders LIMIT 100;"))])
        defer { fixture.cleanUp() }
        let initial = fixture.context
        let goal = "统计最近七天每天的订单数量"
        try await send(fixture, prompt: goal, context: initial)
        XCTAssertNil(fixture.assistant.session(for: initial.tabID).suggestion?.sql)
        var expanded = replacing(initial, tableNames: ["shop.orders"],
                                 schemaMetadata: #"[{"table":"shop.orders","columns":[{"name":"id"},{"name":"created_at"}]}]"#)
        expanded.metadataEpoch = UUID()
        try await send(fixture, prompt: "订单表是 orders", context: expanded)

        let requests = fixture.provider.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let followUp = try XCTUnwrap(requests.last)
        XCTAssertEqual(followUp.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(followUp.messages[0].content, goal)
        XCTAssertEqual(followUp.messages[1].content, question)
        let payload = try payload(followUp.messages[2])
        XCTAssertEqual(payload["request"] as? String, "订单表是 orders")
        let actualMetadata = try XCTUnwrap(payload["selected_schema_metadata"])
        let expectedMetadata = try JSONSerialization.jsonObject(with: Data(expanded.schemaMetadata.utf8))
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: actualMetadata, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: expectedMetadata, options: [.sortedKeys]))
        XCTAssertFalse(followUp.messages[0].content.contains("selected_schema_metadata"))
        let stored = fixture.assistant.session(for: initial.tabID).messages
        XCTAssertEqual(stored.filter { $0.role == .user }.map(\.content), [goal, "订单表是 orders"])
    }

    func testLargeCurrentMetadataDoesNotEvictInitialGoalAcrossManyTurns() async throws {
        let question = reply(sql: nil, explanation: "按下单时间还是支付时间统计？")
        let fixture = try await fixture(replies: [.text(question)])
        defer { fixture.cleanUp() }
        let marker = String(repeating: "m", count: 60_000)
        let context = replacing(fixture.context, tableNames: ["shop.orders"],
                                schemaMetadata: "[{\"table\":\"shop.orders\",\"fixture_metadata_marker\":\"\(marker)\"}]")
        let goal = "原始目标：统计最近七天每天的订单数量"
        try await send(fixture, prompt: goal, context: context)
        for index in 1...16 {
            try await send(fixture, prompt: index == 1 ? "按支付时间" : "补充条件 \(index)", context: context)
        }
        let followUp = try XCTUnwrap(fixture.provider.recordedRequests().last)
        XCTAssertEqual(followUp.messages.first?.role, .user)
        XCTAssertEqual(followUp.messages.first?.content, goal)
        XCTAssertEqual(followUp.messages.dropFirst().first?.content, question)
        XCTAssertEqual(try payload(XCTUnwrap(followUp.messages.last))["request"] as? String, "补充条件 16")
        for message in followUp.messages.dropLast() where message.role == .user {
            XCTAssertFalse(message.content.contains("fixture_metadata_marker"), "Old user turns must not duplicate schema snapshots.")
        }
        let retained = fixture.assistant.session(for: context.tabID).messages
        XCTAssertLessThanOrEqual(retained.count, 24)
        XCTAssertLessThanOrEqual(retained.reduce(0) { $0 + $1.content.utf8.count }, 128 * 1024)
        XCTAssertEqual(retained.first?.content, goal)
    }

    func testConversationDoesNotCrossWorkspaceConnectionTabDatabaseOrWithdrawnSQL() async throws {
        enum Boundary: CaseIterable, Equatable { case workspace, profile, connection, tab, database, sqlWithdrawal, queryError }
        for boundary in Boundary.allCases {
            let fixture = try await fixture()
            defer { fixture.cleanUp() }
            let initial = replacing(fixture.context, sourceSQL: "SELECT 'PREVIOUS_PRIVATE_SQL' FROM shop.orders;")
            try await send(fixture, prompt: "PRIVATE_ORIGINAL_GOAL", context: initial)
            let next: AIContextSnapshot
            switch boundary {
            case .workspace: next = replacing(initial, workspaceID: UUID())
            case .profile: next = replacing(initial, profileID: UUID())
            case .connection: next = replacing(initial, connectionEpoch: UUID())
            case .tab: next = replacing(initial, tabID: UUID())
            case .database: next = replacing(initial, database: "reporting")
            case .sqlWithdrawal: next = replacing(initial, sourceSQL: "")
            case .queryError:
                var changed = initial; changed.queryError = "A different failed query error"
                next = changed
            }
            try await send(fixture, prompt: "NEW_SCOPE_ANSWER", context: next)
            let request = try XCTUnwrap(fixture.provider.recordedRequests().last)
            XCTAssertEqual(request.messages.count, 1, "History crossed \(boundary).")
            XCTAssertFalse(request.messages.contains { $0.content.contains("PRIVATE_ORIGINAL_GOAL") })
            if boundary == .sqlWithdrawal {
                XCTAssertFalse(request.messages.contains { $0.content.contains("PREVIOUS_PRIVATE_SQL") })
            }
        }
    }

    func testProviderProtocolEndpointAndModelChangesResetConversation() async throws {
        enum Boundary: CaseIterable { case protocolKind, endpoint, model }
        for boundary in Boundary.allCases {
            let fixture = try await fixture()
            defer { fixture.cleanUp() }
            try await send(fixture, prompt: "PRIVATE_PROVIDER_GOAL", context: fixture.context)
            var configuration = fixture.store.configuration
            switch boundary {
            case .protocolKind: configuration = .defaults(for: .anthropic); configuration.model = "fixture-model"
            case .endpoint: configuration.baseURL = "https://another-ai.example.invalid/v1"
            case .model: configuration.model = "another-fixture-model"
            }
            try await fixture.store.save(configuration, apiKey: "new-fixture-key")
            try await send(fixture, prompt: "New provider answer", context: fixture.context)
            let request = try XCTUnwrap(fixture.provider.recordedRequests().last)
            XCTAssertEqual(request.messages.count, 1, "History crossed provider \(boundary).")
            XCTAssertFalse(request.messages.contains { $0.content.contains("PRIVATE_PROVIDER_GOAL") })
        }
    }

    func testFailedNewScopeRetryCannotResurrectWithdrawnSQLOrOldAnswer() async throws {
        let privateAnswer = reply(sql: "SELECT 'PRIVATE_ASSISTANT_SQL';", explanation: "PRIVATE_ASSISTANT_EXPLANATION")
        let fixture = try await fixture(replies: [.text(privateAnswer), .failure, .text(reply())])
        defer { fixture.cleanUp() }
        let included = replacing(fixture.context, sourceSQL: "SELECT 'PRIVATE_SOURCE_SQL';")
        let excluded = replacing(included, sourceSQL: "")
        try await send(fixture, prompt: "PRIVATE_FIRST_GOAL", context: included)
        try await send(fixture, prompt: "New request with SQL excluded", context: excluded)
        XCTAssertNotNil(fixture.assistant.session(for: excluded.tabID).errorMessage)
        try await send(fixture, prompt: "Retry without SQL", context: excluded)
        let retry = try XCTUnwrap(fixture.provider.recordedRequests().last)
        XCTAssertEqual(fixture.provider.recordedRequests().count, 3)
        XCTAssertEqual(retry.messages.count, 1)
        for marker in ["PRIVATE_SOURCE_SQL", "PRIVATE_ASSISTANT_SQL", "PRIVATE_ASSISTANT_EXPLANATION", "PRIVATE_FIRST_GOAL"] {
            XCTAssertFalse(retry.messages.contains { $0.content.contains(marker) }, marker)
        }
    }

    func testProviderChangeDuringContextGatheringDoesNotSendAnyRequest() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanUp() }
        let session = fixture.assistant.session(for: fixture.context.tabID)
        var changed = fixture.store.configuration
        changed.baseURL = "https://changed-during-context.example.invalid/v1"
        fixture.assistant.start(tabID: fixture.context.tabID, action: .generate, prompt: "Keep this request private") {
            try await fixture.store.save(changed, apiKey: "changed-fixture-key")
            return fixture.context
        }
        try await settle(session)
        XCTAssertEqual(fixture.provider.recordedRequests().count, 0)
        XCTAssertNil(session.suggestion)
        XCTAssertEqual(session.errorMessage, AIConfigurationError.configurationChanged.localizedDescription)
        XCTAssertEqual(try fixture.store.configuration.endpointURL().host, "changed-during-context.example.invalid")
    }

    func testProviderFailureRestoresSubmittedPromptWhenComposerWasCleared() async throws {
        let fixture = try await fixture(replies: [.failure])
        defer { fixture.cleanUp() }
        let session = fixture.assistant.session(for: fixture.context.tabID), submitted = "统计最近七天的订单"
        session.prompt = submitted
        fixture.assistant.start(tabID: fixture.context.tabID, action: .generate, prompt: submitted) { fixture.context }
        session.prompt = "" // The Send button clears the composer immediately.
        try await settle(session)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(session.prompt, submitted)
        XCTAssertTrue(session.messages.isEmpty)
    }

    func testCancellationRestoresSubmittedPromptWhenComposerWasCleared() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanUp() }
        let gate = AIConversationContextGate()
        let session = fixture.assistant.session(for: fixture.context.tabID), submitted = "按支付日期统计"
        session.prompt = submitted
        fixture.assistant.start(tabID: fixture.context.tabID, action: .generate, prompt: submitted) {
            await gate.pause()
            return fixture.context
        }
        session.prompt = ""
        await gate.waitUntilPaused()
        fixture.assistant.cancel(tabID: fixture.context.tabID)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.prompt, submitted)
        XCTAssertNotNil(session.errorMessage)
        await gate.release()
        await Task.yield()
        XCTAssertEqual(fixture.provider.recordedRequests().count, 0)
    }

    func testFailureDoesNotOverwriteNewerComposerText() async throws {
        let fixture = try await fixture(replies: [.failure])
        defer { fixture.cleanUp() }
        let session = fixture.assistant.session(for: fixture.context.tabID)
        fixture.assistant.start(tabID: fixture.context.tabID, action: .generate, prompt: "Original submitted prompt") { fixture.context }
        session.prompt = "Newer prompt must survive"
        try await settle(session)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(session.prompt, "Newer prompt must survive")
    }

    func testClearAndRemoveDoNotRestoreSubmittedPromptFromCancelledRequest() async throws {
        for removing in [false, true] {
            let fixture = try await fixture()
            defer { fixture.cleanUp() }
            let gate = AIConversationContextGate(), tabID = fixture.context.tabID
            let session = fixture.assistant.session(for: tabID)
            session.prompt = "Previously sent prompt"
            fixture.assistant.start(tabID: tabID, action: .generate, prompt: session.prompt) {
                await gate.pause()
                return fixture.context
            }
            session.prompt = ""
            await gate.waitUntilPaused()
            if removing { fixture.assistant.remove(tabID: tabID) }
            else { fixture.assistant.clear(tabID: tabID) }
            XCTAssertEqual(session.prompt, "")
            XCTAssertFalse(session.isRunning)
            if removing { XCTAssertNil(fixture.assistant.sessions[tabID]) }
            else { XCTAssertTrue(session.messages.isEmpty); XCTAssertNil(session.errorMessage) }
            await gate.release()
            await Task.yield()
            XCTAssertEqual(session.prompt, "")
            XCTAssertEqual(fixture.provider.recordedRequests().count, 0)
        }
    }

    private func fixture(replies: [AIConversationReply] = []) async throws -> AIConversationFixture {
        let suite = "AIAssistantConversation.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = AIConfigurationStore(defaults: defaults, keychain: AIConversationSecrets())
        var configuration = AIConfiguration.defaults(for: .openAI); configuration.model = "fixture-model"
        try await store.save(configuration, apiKey: "fixture-key")
        let provider = AIConversationProvider(replies: replies, defaultReply: reply())
        let assistant = AIAssistantModel(provider: provider, configurationStore: store)
        let context = AIContextSnapshot(workspaceID: UUID(), profileID: UUID(), connectionEpoch: UUID(),
            tabID: UUID(), documentRevision: 0, database: "shop", tableNames: [], sourceSQL: "",
            selection: NSRange(location: 0, length: 0), schemaMetadata: "[]", metadataEpoch: UUID())
        return AIConversationFixture(suite: suite, defaults: defaults, store: store, provider: provider,
                                     assistant: assistant, context: context)
    }

    private func send(_ fixture: AIConversationFixture, prompt: String, context: AIContextSnapshot) async throws {
        fixture.assistant.start(tabID: context.tabID, action: .generate, prompt: prompt) { context }
        let session = fixture.assistant.session(for: context.tabID)
        try await settle(session)
    }

    private func settle(_ session: AIAssistantSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.isRunning {
            guard ContinuousClock.now < deadline else { throw AIAssistanceError("Conversation fixture timed out.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func payload(_ message: AIChatMessage) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.content.utf8)) as? [String: Any])
    }

    private func reply(sql: String? = "SELECT 1;", explanation: String = "Fixture response") -> String {
        let object: [String: Any] = ["sql": sql as Any? ?? NSNull(), "explanation": explanation, "assumptions": []]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func replacing(_ context: AIContextSnapshot, workspaceID: UUID? = nil, profileID: UUID? = nil,
                           connectionEpoch: UUID? = nil, tabID: UUID? = nil, database: String? = nil,
                           tableNames: [String]? = nil, sourceSQL: String? = nil,
                           schemaMetadata: String? = nil) -> AIContextSnapshot {
        var result = AIContextSnapshot(workspaceID: workspaceID ?? context.workspaceID,
            profileID: profileID ?? context.profileID, connectionEpoch: connectionEpoch ?? context.connectionEpoch,
            tabID: tabID ?? context.tabID, documentRevision: context.documentRevision,
            database: database ?? context.database, tableNames: tableNames ?? context.tableNames,
            sourceSQL: sourceSQL ?? context.sourceSQL, selection: context.selection,
            schemaMetadata: schemaMetadata ?? context.schemaMetadata, metadataEpoch: context.metadataEpoch)
        result.queryError = context.queryError
        return result
    }
}

@MainActor private struct AIConversationFixture {
    let suite: String
    let defaults: UserDefaults
    let store: AIConfigurationStore
    let provider: AIConversationProvider
    let assistant: AIAssistantModel
    let context: AIContextSnapshot
    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

private enum AIConversationReply: Sendable { case text(String), failure }

private final class AIConversationProvider: AIProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [AIConversationReply]
    private let defaultReply: String
    private var requests: [AIProviderRequest] = []
    init(replies: [AIConversationReply], defaultReply: String) { self.replies = replies; self.defaultReply = defaultReply }
    func recordedRequests() -> [AIProviderRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func stream(_ request: AIProviderRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        let index = requests.count
        requests.append(request)
        let response = index < replies.count ? replies[index] : .text(defaultReply)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            switch response {
            case .text(let text): continuation.yield(text); continuation.finish()
            case .failure: continuation.finish(throwing: AIAssistanceError("Conversation fixture failure."))
            }
        }
    }
}

private actor AIConversationSecrets: PasswordStoring {
    private var values: [UUID: String] = [:]
    func save(_ password: String, for profileID: UUID) { values[profileID] = password }
    func password(for profileID: UUID) -> String? { values[profileID] }
    func deletePassword(for profileID: UUID) { values.removeValue(forKey: profileID) }
}

private actor AIConversationContextGate {
    private var paused: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { continuation in
            paused = continuation
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }
    func waitUntilPaused() async {
        if paused != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { paused?.resume(); paused = nil }
}
