import Foundation

enum AIProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic
    var id: String { rawValue }
    var displayName: String { self == .openAI ? "OpenAI" : "Anthropic" }
    fileprivate var endpointPath: String { self == .openAI ? "/chat/completions" : "/messages" }
}

/// Persistable metadata only. API keys live in the AI-specific Keychain service.
struct AIConfiguration: Codable, Equatable, Sendable {
    var protocolKind: AIProtocol
    var baseURL: String
    var model: String
    var apiKeyRecordID: UUID

    static func defaults(for protocolKind: AIProtocol) -> AIConfiguration {
        AIConfiguration(protocolKind: protocolKind,
                        baseURL: protocolKind == .openAI ? "https://api.openai.com/v1" : "https://api.anthropic.com/v1",
                        model: "", apiKeyRecordID: UUID())
    }

    /// Accept a base URL or complete protocol endpoint. Only loopback HTTP is
    /// permitted; credentials, query parameters and fragments are rejected.
    func endpointURL() throws -> URL {
        let input = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              let originalHost = components.host, !originalHost.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw AIConfigurationError.invalidURL
        }
        let host = originalHost.lowercased()
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback),
              components.port.map({ (1...65535).contains($0) }) ?? true,
              !host.contains("%"), !host.contains("\\") else { throw AIConfigurationError.invalidURL }
        components.scheme = scheme; components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) { components.port = nil }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/v1" }
        let otherEndpoint = protocolKind == .openAI ? AIProtocol.anthropic.endpointPath : AIProtocol.openAI.endpointPath
        guard !path.hasSuffix(otherEndpoint) else { throw AIConfigurationError.wrongEndpoint }
        if !path.hasSuffix(protocolKind.endpointPath) { path += protocolKind.endpointPath }
        components.percentEncodedPath = path
        guard let url = components.url, url.host != nil else { throw AIConfigurationError.invalidURL }
        return url
    }

    func validated() throws -> AIConfiguration {
        let endpoint = try endpointURL()
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty,
              !trimmedModel.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AIConfigurationError.missingModel
        }
        var normalized = self
        normalized.model = trimmedModel
        let endpointString = endpoint.absoluteString
        // Keep the complete endpoint whenever stripping the protocol suffix
        // would alter its destination on the next normalization (an origin
        // endpoint would gain /v1, and repeated path slashes could be removed).
        normalized.baseURL = String(endpointString.dropLast(protocolKind.endpointPath.count))
        if (try? normalized.endpointURL()) != endpoint {
            normalized.baseURL = endpointString
        }
        return normalized
    }
}

enum AIConfigurationError: LocalizedError, Equatable {
    case invalidURL, wrongEndpoint, missingModel, missingAPIKey, invalidAPIKey, keyUnavailable, configurationChanged, savingConfiguration
    var errorDescription: String? {
        let message: String
        switch self {
        case .invalidURL: message = "Use an HTTPS URL, or HTTP on localhost. Credentials, query parameters and fragments are not allowed."
        case .wrongEndpoint: message = "The URL uses the other AI protocol's endpoint. Enter the matching base URL."
        case .missingModel: message = "Enter a model name."
        case .missingAPIKey: message = "Enter an API key for this AI endpoint."
        case .invalidAPIKey: message = "The API key cannot contain control characters."
        case .keyUnavailable: message = "The saved AI API key is unavailable. Enter it again in AI Configuration."
        case .configurationChanged: message = "AI configuration changed while loading its API key. Try again."
        case .savingConfiguration: message = "AI configuration is being saved. Try again when saving finishes."
        }
        return NSLocalizedString(message, comment: "AI configuration validation")
    }
}
