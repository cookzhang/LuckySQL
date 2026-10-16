import Foundation
import Combine

@MainActor final class AIAssistantSession: ObservableObject {
    @Published var prompt = ""
    @Published var action: AIAssistantAction = .generate
    @Published var includeSQL = false
    @Published fileprivate(set) var isRunning = false
    @Published fileprivate(set) var streamingText = ""
    @Published fileprivate(set) var errorMessage: String?
    @Published fileprivate(set) var suggestion: AISuggestion?
    @Published fileprivate(set) var context: AIContextSnapshot?
    @Published fileprivate(set) var messages: [AIChatMessage] = []
    @Published fileprivate(set) var historyNotice: String?
    @Published fileprivate(set) var pendingPrompt: String?
    fileprivate var requestID: UUID?
    fileprivate var providerScope: String?
    fileprivate var isPreparingContext = false
    fileprivate var task: Task<Void, Never>?
}

/// Token updates only publish to the assistant panel, never to the database workspace.
@MainActor final class AIAssistantModel: ObservableObject {
    @Published private(set) var sessions: [UUID: AIAssistantSession] = [:]
    private let provider: any AIProviding
    private let configurationStore: AIConfigurationStore
    init(provider: any AIProviding = AIHTTPClient(), configurationStore: AIConfigurationStore? = nil) {
        self.provider = provider; self.configurationStore = configurationStore ?? .shared
    }
    func session(for tabID: UUID) -> AIAssistantSession {
        if let session = sessions[tabID] { return session }
        let session = AIAssistantSession(); sessions[tabID] = session; return session
    }
    func start(tabID: UUID, action: AIAssistantAction, prompt: String,
               context: @escaping @MainActor () async throws -> AIContextSnapshot) {
        let session = session(for: tabID)
        guard !session.isRunning else { return }
        session.errorMessage = nil; session.suggestion = nil; session.streamingText = ""
        session.pendingPrompt = prompt
        session.isRunning = true; session.isPreparingContext = true
        let requestID = UUID(); session.requestID = requestID
        let provider = self.provider, store = configurationStore
        session.task = Task { [weak session] in
            guard let session else { return }
            defer {
                if session.requestID == requestID {
                    session.pendingPrompt = nil
                    session.isRunning = false; session.isPreparingContext = false; session.task = nil
                }
            }
            do {
                let credentials = try await store.credentials()
                try Task.checkCancellation()
                guard session.requestID == requestID else { return }
                let scope = try Self.providerScope(credentials.configuration)
                let snapshot = try await context()
                try Task.checkCancellation()
                guard session.requestID == requestID else { return }
                guard try Self.providerScope(store.configuration.validated()) == scope else {
                    throw AIConfigurationError.configurationChanged
                }
                session.isPreparingContext = false
                let userMessage = try snapshot.promptData(action: action, prompt: prompt)
                let keepsHistory = session.providerScope == scope &&
                    session.context.map { snapshot.canContinueConversation(as: $0) } == true
                let previous = keepsHistory ? Self.retainedHistory(session.messages) : []
                session.historyNotice = !keepsHistory && !session.messages.isEmpty
                    ? NSLocalizedString("Conversation restarted because the connection, database, model or shared SQL changed.", comment: "") : nil
                // History and its scope must change together, even when this
                // request fails. A retry must never resurrect excluded SQL.
                session.messages = previous
                session.context = snapshot; session.providerScope = scope
                let messages = previous + [AIChatMessage(role: .user, content: userMessage)]
                let request = AIProviderRequest(configuration: credentials.configuration, apiKey: credentials.apiKey,
                                                systemPrompt: AIContextBuilder.systemPrompt, messages: messages)
                var output = ""
                var lastPublish = ContinuousClock.now
                for try await delta in provider.stream(request) {
                    try Task.checkCancellation()
                    guard session.requestID == requestID else { return }
                    output += delta
                    guard output.utf8.count <= 1024 * 1024 else { throw AIAssistanceError("The model response is too large.") }
                    if lastPublish.duration(to: .now) >= .milliseconds(80) {
                        session.streamingText = output; lastPublish = .now
                    }
                }
                try Task.checkCancellation()
                guard session.requestID == requestID else { return }
                session.streamingText = output
                session.suggestion = try AISuggestion.parse(output, source: snapshot, action: action)
                // Retain human intent, not repeated SQL/schema snapshots. Only
                // the newest wire message carries the current database context.
                let intent = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? action.displayName : prompt
                session.messages = Self.retainedHistory(previous + [AIChatMessage(role: .user, content: intent),
                    AIChatMessage(role: .assistant, content: output)])
            } catch {
                guard session.requestID == requestID else { return }
                session.suggestion = nil
                if session.prompt.isEmpty { session.prompt = prompt }
                session.errorMessage = (error is CancellationError || Task.isCancelled)
                    ? NSLocalizedString("AI request stopped. No SQL was changed or executed.", comment: "") : error.localizedDescription
            }
        }
    }
    func cancel(tabID: UUID, restoringPrompt: Bool = true) {
        guard let session = sessions[tabID], session.isRunning else { return }
        session.task?.cancel(); session.task = nil; session.requestID = nil
        if restoringPrompt, session.prompt.isEmpty, let prompt = session.pendingPrompt { session.prompt = prompt }
        session.pendingPrompt = nil
        session.isRunning = false; session.isPreparingContext = false; session.suggestion = nil
        session.errorMessage = NSLocalizedString("AI request stopped. No SQL was changed or executed.", comment: "")
    }
    func clear(tabID: UUID) {
        cancel(tabID: tabID, restoringPrompt: false)
        guard let session = sessions[tabID] else { return }
        session.messages = []; session.suggestion = nil; session.context = nil
        session.providerScope = nil
        session.streamingText = ""; session.errorMessage = nil; session.historyNotice = nil
    }
    func remove(tabID: UUID) { cancel(tabID: tabID, restoringPrompt: false); sessions.removeValue(forKey: tabID) }
    func cancelContextRequests() {
        for id in Array(sessions.keys) where sessions[id]?.isPreparingContext == true {
            cancel(tabID: id)
        }
    }
    func invalidateConnection() {
        for id in sessions.keys { clear(tabID: id) }
    }

    func continuation(for tabID: UUID, matching snapshot: AIContextSnapshot) -> (context: AIContextSnapshot, messages: [AIChatMessage])? {
        guard let session = sessions[tabID], let previous = session.context,
              let scope = try? Self.providerScope(configurationStore.configuration.validated()),
              session.providerScope == scope, snapshot.canContinueConversation(as: previous) else { return nil }
        return (previous, session.messages)
    }

    private static func providerScope(_ configuration: AIConfiguration) throws -> String {
        configuration.protocolKind.rawValue + "|" + (try configuration.endpointURL().absoluteString) + "|" + configuration.model
    }

    private static func retainedHistory(_ messages: [AIChatMessage]) -> [AIChatMessage] {
        var turns: [[AIChatMessage]] = []
        var index = 0
        while index + 1 < messages.count {
            if messages[index].role == .user && messages[index + 1].role == .assistant {
                turns.append([messages[index], messages[index + 1]]); index += 2
            } else { index += 1 }
        }
        // Pin the initial goal/question, then keep recent complete turns. Never
        // trim a user answer away from the assistant question it belongs to.
        while turns.count > 12 { turns.remove(at: 1) }
        while turns.flatMap({ $0 }).reduce(0, { $0 + $1.content.utf8.count }) > 128 * 1024 {
            guard turns.count > 1 else { return [] }
            turns.remove(at: turns.count > 2 ? 1 : 0)
        }
        return turns.flatMap { $0 }
    }
}
