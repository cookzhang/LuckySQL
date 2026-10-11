import Foundation

struct AIChatMessage: Sendable, Equatable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: String

    init(role: Role, content: String) {
        self.role = role; self.content = content
    }
}

struct AIProviderRequest: Sendable {
    let configuration: AIConfiguration
    let apiKey: String
    let systemPrompt: String
    let messages: [AIChatMessage]

    init(configuration: AIConfiguration, apiKey: String, systemPrompt: String, messages: [AIChatMessage]) {
        self.configuration = configuration; self.apiKey = apiKey
        self.systemPrompt = systemPrompt; self.messages = messages
    }
}

protocol AIProviding: Sendable {
    func stream(_ request: AIProviderRequest) -> AsyncThrowingStream<String, Error>
}

/// Provider response bodies can echo SQL, credentials or connection details.
/// Errors shown in the app intentionally contain only locally defined text.
enum AIProviderError: LocalizedError, Sendable, Equatable {
    case invalidAPIKey
    case requestTooLarge
    case httpStatus(Int)
    case redirectRejected
    case invalidResponse
    case invalidEvent
    case providerRejected
    case unsupportedResponse
    case incompleteResponse
    case emptyResponse
    case responseTooLarge
    case outputTooLarge
    case networkFailure

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return NSLocalizedString("Enter a valid AI API key.", comment: "AI provider error")
        case .requestTooLarge:
            return NSLocalizedString("The AI request is too large. Include fewer tables or less SQL.", comment: "AI provider error")
        case .httpStatus(let status):
            return String(format: NSLocalizedString("The AI service returned HTTP %ld. Check the service, model and API key.", comment: "AI provider HTTP error"), status)
        case .redirectRejected:
            return NSLocalizedString("The AI service redirected the request. Use its direct API endpoint.", comment: "AI provider error")
        case .invalidResponse:
            return NSLocalizedString("The AI service did not return a valid streaming response.", comment: "AI provider error")
        case .invalidEvent:
            return NSLocalizedString("The AI service returned an invalid stream event.", comment: "AI provider error")
        case .providerRejected:
            return NSLocalizedString("The AI service reported an error. Check the service, model and request limits.", comment: "AI provider error")
        case .unsupportedResponse:
            return NSLocalizedString("The AI service returned an unsupported response. Tool calls are disabled.", comment: "AI provider error")
        case .incompleteResponse:
            return NSLocalizedString("The AI response ended before it was complete. Generate the suggestion again.", comment: "AI provider error")
        case .emptyResponse:
            return NSLocalizedString("The AI service returned no text.", comment: "AI provider error")
        case .responseTooLarge:
            return NSLocalizedString("The AI response exceeded the stream size limit.", comment: "AI provider error")
        case .outputTooLarge:
            return NSLocalizedString("The AI suggestion exceeded the text size limit.", comment: "AI provider error")
        case .networkFailure:
            return NSLocalizedString("Unable to reach the AI service. Check the endpoint and network connection.", comment: "AI provider error")
        }
    }
}
