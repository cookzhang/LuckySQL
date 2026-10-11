import Foundation

struct AIHTTPClient: AIProviding {
    private let transport: AIHTTPTransport

    /// Copying the configuration preserves URLProtocol fixtures while ensuring
    /// even injected sessions use our redirect and credential privacy policy.
    init(session: URLSession = .shared) {
        transport = AIHTTPTransport(configuration: session.configuration)
    }

    func stream(_ request: AIProviderRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await transport.stream(request) { text in
                        if case .terminated = continuation.yield(text) { throw CancellationError() }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let error as AIProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    // Do not forward raw networking errors: they may contain URLs.
                    continuation.finish(throwing: AIProviderError.networkFailure)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private final class AIHTTPTransport: @unchecked Sendable {
    private let session: URLSession
    private static let responseLimit = 1024 * 1024
    private static let outputLimit = 512 * 1024

    init(configuration: URLSessionConfiguration) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = configuration.httpAdditionalHeaders?.filter {
            !["authorization", "x-api-key", "cookie"].contains(String(describing: $0.key).lowercased())
        }
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: AINoRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func stream(_ input: AIProviderRequest, emit: (String) throws -> Void) async throws {
        try Task.checkCancellation()
        let request = try Self.request(input)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        if (300..<400).contains(response.statusCode) { throw AIProviderError.redirectRejected }
        guard (200..<300).contains(response.statusCode) else { throw AIProviderError.httpStatus(response.statusCode) }
        guard response.url == request.url,
              response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text/event-stream" else {
            throw AIProviderError.invalidResponse
        }

        var decoder = AISSEDecoder()
        var state = AIStreamState(protocolKind: input.configuration.protocolKind)
        var responseBytes = 0, outputBytes = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            responseBytes += 1
            guard responseBytes <= Self.responseLimit else { throw AIProviderError.responseTooLarge }
            if let event = try decoder.append(byte) {
                let action = try state.consume(event)
                switch action {
                case .text(let text):
                    outputBytes += text.utf8.count
                    guard outputBytes <= Self.outputLimit else { throw AIProviderError.outputTooLarge }
                    if !text.isEmpty { try emit(text) }
                case .complete:
                    guard outputBytes > 0 else { throw AIProviderError.emptyResponse }
                    return
                case .none: break
                }
            }
        }
        // An event without its final blank line is not a completed SSE event.
        // Likewise, a dropped connection must never promote partial SQL to ready.
        throw AIProviderError.incompleteResponse
    }

    private static func request(_ input: AIProviderRequest) throws -> URLRequest {
        let configuration: AIConfiguration
        do { configuration = try input.configuration.validated() }
        catch { throw AIProviderError.invalidResponse }
        let endpoint: URL
        do { endpoint = try configuration.endpointURL() }
        catch { throw AIProviderError.invalidResponse }
        guard !input.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.apiKey.utf8.count <= 4096,
              !input.apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AIProviderError.invalidAPIKey
        }
        let messages = input.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = ["model": configuration.model, "stream": true]
        var request = URLRequest(url: endpoint)
        switch configuration.protocolKind {
        case .openAI:
            body["messages"] = [["role": "system", "content": input.systemPrompt]] + messages
            body["max_completion_tokens"] = 4096
            request.setValue("Bearer \(input.apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            body["messages"] = messages
            body["system"] = input.systemPrompt
            body["max_tokens"] = 4096
            request.setValue(input.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= Self.responseLimit else { throw AIProviderError.requestTooLarge }
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        return request
    }
}

private final class AINoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // HTTPS trust uses the system policy. Never answer a Basic/Digest prompt
        // using credentials from another session or the user's credential store.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

struct AISSEEvent: Equatable {
    let name: String?
    let data: String
}

/// Decode bytes before decoding UTF-8 so network chunks may split any scalar.
/// Each event is bounded, including ignored fields and comments.
struct AISSEDecoder {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?
    private var eventBytes = 0
    private var afterCR = false
    private static let eventLimit = 256 * 1024

    mutating func append(_ byte: UInt8) throws -> AISSEEvent? {
        if afterCR {
            afterCR = false
            if byte == 10 { return nil }
        }
        eventBytes += 1
        guard eventBytes <= Self.eventLimit else { throw AIProviderError.responseTooLarge }
        if byte == 13 || byte == 10 {
            afterCR = byte == 13
            return try consumeLine()
        }
        line.append(byte)
        return nil
    }

    private mutating func consumeLine() throws -> AISSEEvent? {
        guard let text = String(bytes: line, encoding: .utf8) else { throw AIProviderError.invalidEvent }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            let event = dataLines.isEmpty ? nil : AISSEEvent(name: eventName, data: dataLines.joined(separator: "\n"))
            dataLines.removeAll(keepingCapacity: true); eventName = nil; eventBytes = 0
            return event
        }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = parts[0]
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "data" { dataLines.append(value) }
        else if field == "event" { eventName = value }
        return nil
    }
}

private struct AIStreamState {
    enum Action { case text(String), complete, none }
    let protocolKind: AIProtocol
    private var finishedText = false
    private var anthropicStopReason: String?

    init(protocolKind: AIProtocol) { self.protocolKind = protocolKind }

    mutating func consume(_ event: AISSEEvent) throws -> Action {
        if event.name == "error" { throw AIProviderError.providerRejected }
        if protocolKind == .openAI && event.data == "[DONE]" {
            guard finishedText else { throw AIProviderError.incompleteResponse }
            return .complete
        }
        guard let data = event.data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.invalidEvent
        }
        if object["error"] != nil || object["type"] as? String == "error" {
            throw AIProviderError.providerRejected
        }
        switch protocolKind {
        case .openAI: return try openAI(object)
        case .anthropic: return try anthropic(object, eventName: event.name)
        }
    }

    private mutating func openAI(_ object: [String: Any]) throws -> Action {
        guard let choices = object["choices"] as? [[String: Any]], choices.count <= 1 else {
            throw AIProviderError.invalidEvent
        }
        guard let choice = choices.first else { return .none } // Optional usage event.
        guard let delta = choice["delta"] as? [String: Any] else { throw AIProviderError.invalidEvent }
        if delta["tool_calls"] != nil || delta["function_call"] != nil { throw AIProviderError.unsupportedResponse }
        if let reason = choice["finish_reason"] as? String {
            guard reason == "stop" else { throw AIProviderError.incompleteResponse }
            finishedText = true
        }
        if let content = delta["content"], !(content is NSNull) {
            guard let text = content as? String else { throw AIProviderError.invalidEvent }
            return .text(text)
        }
        return .none
    }

    private mutating func anthropic(_ object: [String: Any], eventName: String?) throws -> Action {
        guard let type = object["type"] as? String, eventName == nil || eventName == type else {
            throw AIProviderError.invalidEvent
        }
        switch type {
        case "content_block_start":
            guard let block = object["content_block"] as? [String: Any] else { throw AIProviderError.invalidEvent }
            if block["type"] as? String == "tool_use" { throw AIProviderError.unsupportedResponse }
            if block["type"] as? String == "text", let text = block["text"] as? String { return .text(text) }
            return .none
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any], let deltaType = delta["type"] as? String else {
                throw AIProviderError.invalidEvent
            }
            if deltaType == "input_json_delta" { throw AIProviderError.unsupportedResponse }
            guard deltaType == "text_delta" else { return .none }
            guard let text = delta["text"] as? String else { throw AIProviderError.invalidEvent }
            return .text(text)
        case "message_delta":
            guard let delta = object["delta"] as? [String: Any] else { throw AIProviderError.invalidEvent }
            if let reason = delta["stop_reason"] as? String {
                guard ["end_turn", "stop_sequence"].contains(reason) else { throw AIProviderError.incompleteResponse }
                anthropicStopReason = reason
            }
            return .none
        case "message_stop":
            guard anthropicStopReason != nil else { throw AIProviderError.incompleteResponse }
            return .complete
        case "message_start", "content_block_stop", "ping": return .none
        default: return .none // Anthropic may add informational event types.
        }
    }
}
