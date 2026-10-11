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
        session.isRunning = true; session.isPreparingContext = true
        let requestID = UUID(); session.requestID = requestID
        let provider = self.provider, store = configurationStore
        session.task = Task { [weak session] in
            guard let session else { return }
            defer {
                if session.requestID == requestID {
                    session.isRunning = false; session.isPreparingContext = false; session.task = nil
                }
            }
            do {
                let snapshot = try await context()
                try Task.checkCancellation()
                guard session.requestID == requestID else { return }
                session.isPreparingContext = false
                let userMessage = try snapshot.promptData(action: action, prompt: prompt)
                let credentials = try await store.credentials()
                try Task.checkCancellation()
                guard session.requestID == requestID else { return }
                let scope = credentials.configuration.protocolKind.rawValue + "|" +
                    (try credentials.configuration.endpointURL().absoluteString) + "|" + credentials.configuration.model
                let keepsHistory = session.providerScope == scope &&
                    session.context.map { snapshot.hasSameConversationScope(as: $0) } == true
                var previous = keepsHistory ? Array(session.messages.suffix(6)) : []
                while previous.reduce(0, { $0 + $1.content.utf8.count }) > 128 * 1024 { previous.removeFirst() }
                if previous.first?.role == .assistant { previous.removeFirst() }
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
                var retained = Array((messages + [AIChatMessage(role: .assistant, content: output)]).suffix(8))
                while retained.reduce(0, { $0 + $1.content.utf8.count }) > 128 * 1024 { retained.removeFirst() }
                // A conversation starts with a user message on both supported protocols.
                if retained.first?.role == .assistant { retained.removeFirst() }
                session.messages = retained
            } catch {
                guard session.requestID == requestID else { return }
                session.suggestion = nil
                session.errorMessage = (error is CancellationError || Task.isCancelled)
                    ? NSLocalizedString("AI request stopped. No SQL was changed or executed.", comment: "") : error.localizedDescription
            }
        }
    }
    func cancel(tabID: UUID) {
        guard let session = sessions[tabID], session.isRunning else { return }
        session.task?.cancel(); session.task = nil; session.requestID = nil
        session.isRunning = false; session.isPreparingContext = false; session.suggestion = nil
        session.errorMessage = NSLocalizedString("AI request stopped. No SQL was changed or executed.", comment: "")
    }
    func clear(tabID: UUID) {
        cancel(tabID: tabID)
        guard let session = sessions[tabID] else { return }
        session.messages = []; session.suggestion = nil; session.context = nil
        session.providerScope = nil
        session.streamingText = ""; session.errorMessage = nil
    }
    func remove(tabID: UUID) { cancel(tabID: tabID); sessions.removeValue(forKey: tabID) }
    func cancelContextRequests() {
        for id in Array(sessions.keys) where sessions[id]?.isPreparingContext == true {
            cancel(tabID: id)
        }
    }
    func invalidateConnection() {
        for id in sessions.keys { clear(tabID: id) }
    }
}
