import Foundation
import XCTest
@testable import LuckySQL

final class AIHTTPClientTests: XCTestCase {
    func testOpenAIRequestAndSplitUTF8MultilineSSE() async throws {
        let text = ": heartbeat\r\n\r\ndata: {\"choices\": [\r\ndata: {\"delta\": {\"content\": \"SELECT '你好🙂';\"}, \"finish_reason\": null}]}\r\n\r\n"
            + openAIFinish + "data: [DONE]\r\n\r\n"
        let fixture = AIHTTPFixture(chunks: Data(text.utf8).map { Data([$0]) })
        let (client, session, token) = makeClient(fixture)
        defer { session.invalidateAndCancel(); AIHTTPFixtureProtocol.registry.remove(token) }
        let result = try await collect(client, request: request(.openAI))
        XCTAssertEqual(result, "SELECT '你好🙂';")
        let captured = try XCTUnwrap(AIHTTPFixtureProtocol.registry.requests(token).first)
        XCTAssertEqual(captured.url?.absoluteString, "https://ai.example.invalid/v1/chat/completions")
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        XCTAssertNil(captured.value(forHTTPHeaderField: "x-api-key"))
        let body = try body(captured)
        XCTAssertEqual(body["model"] as? String, "fixture-model")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 4096)
        XCTAssertNil(body["temperature"]); XCTAssertNil(body["tools"]); XCTAssertNil(body["tool_choice"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": "Only generate SQL."],
                                 ["role": "user", "content": "List orders"],
                                 ["role": "assistant", "content": "SELECT 1;"],
                                 ["role": "user", "content": "Use a limit"]])
    }

    func testAnthropicNativeHeadersSystemAndCompletion() async throws {
        let stream = anthropicEvent("message_start", ["message": ["role": "assistant"]])
            + anthropicEvent("content_block_start", ["content_block": ["type": "text", "text": ""]])
            + anthropicEvent("content_block_delta", ["delta": ["type": "text_delta", "text": "SELECT 1;"]])
            + anthropicEvent("message_delta", ["delta": ["stop_reason": "end_turn"]])
            + anthropicEvent("message_stop", [:])
        let (client, session, token) = makeClient(AIHTTPFixture(chunks: [Data(stream.utf8)]))
        defer { session.invalidateAndCancel(); AIHTTPFixtureProtocol.registry.remove(token) }
        let result = try await collect(client, request: request(.anthropic))
        XCTAssertEqual(result, "SELECT 1;")
        let captured = try XCTUnwrap(AIHTTPFixtureProtocol.registry.requests(token).first)
        XCTAssertEqual(captured.url?.path, "/v1/messages")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(captured.value(forHTTPHeaderField: "Authorization"))
        let body = try body(captured)
        XCTAssertEqual(body["system"] as? String, "Only generate SQL.")
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertNil(body["max_completion_tokens"]); XCTAssertNil(body["tools"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertFalse(messages.contains { $0["role"] == "system" })
    }

    func testEOFLengthAndMissingStopMarkersAreIncomplete() async throws {
        let cases: [(AIProtocol, String)] = [
            (.openAI, openAIText("SELECT 1;")),
            (.openAI, openAIText("SELECT 1;") + openAIFinish),
            (.openAI, openAIText("SELECT 1;") + "data: [DONE]\n\n"),
            (.openAI, openAIText("SELECT 1;") + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n" + "data: [DONE]\n\n"),
            (.anthropic, anthropicEvent("content_block_delta", ["delta": ["type": "text_delta", "text": "SELECT 1;"]]) + anthropicEvent("message_stop", [:])),
            (.anthropic, anthropicEvent("message_delta", ["delta": ["stop_reason": "max_tokens"]]))
        ]
        for (kind, stream) in cases {
            let (client, session, token) = makeClient(AIHTTPFixture(chunks: [Data(stream.utf8)]))
            defer { session.invalidateAndCancel(); AIHTTPFixtureProtocol.registry.remove(token) }
            await assertFailure(.incompleteResponse) { try await self.collect(client, request: self.request(kind)) }
            XCTAssertEqual(AIHTTPFixtureProtocol.registry.requests(token).count, 1, "Incomplete streams must not retry.")
        }
    }

    func testHTTPAndStreamErrorsDoNotEchoRemoteSecretsOrRetry() async throws {
        let secret = "private-SQL fixture-key user@internal-database"
        let fixtures: [(AIHTTPFixture, AIProtocol, AIProviderError)] = [
            (AIHTTPFixture(status: 401, chunks: [Data(secret.utf8)]), .openAI, .httpStatus(401)),
            (AIHTTPFixture(status: 429, chunks: [Data(secret.utf8)]), .anthropic, .httpStatus(429)),
            (AIHTTPFixture(chunks: [Data(("data: {\"error\":{\"message\":\"\(secret)\"}}\n\n").utf8)]), .openAI, .providerRejected),
            (AIHTTPFixture(chunks: [Data(anthropicEvent("error", ["error": ["message": secret]]).utf8)]), .anthropic, .providerRejected)
        ]
        for (fixture, kind, expected) in fixtures {
            let (client, session, token) = makeClient(fixture)
            defer { session.invalidateAndCancel(); AIHTTPFixtureProtocol.registry.remove(token) }
            await assertFailure(expected) { try await self.collect(client, request: self.request(kind)) }
            XCTAssertFalse(expected.localizedDescription.contains(secret))
            XCTAssertFalse(expected.localizedDescription.contains("fixture-key"))
            XCTAssertEqual(AIHTTPFixtureProtocol.registry.requests(token).count, 1)
        }
    }

    func testInvalidEventsEmptyTextAndToolCallsAreRejected() async throws {
        let fixtures: [(String, AIProtocol, AIProviderError)] = [
            ("data: not-json\n\n", .openAI, .invalidEvent),
            (openAIFinish + "data: [DONE]\n\n", .openAI, .emptyResponse),
            ("data: {\"choices\":[{\"delta\":{\"tool_calls\":[]}}]}\n\n", .openAI, .unsupportedResponse),
            (anthropicEvent("content_block_start", ["content_block": ["type": "tool_use"]]), .anthropic, .unsupportedResponse)
        ]
        for (stream, kind, expected) in fixtures {
            let (client, session, token) = makeClient(AIHTTPFixture(chunks: [Data(stream.utf8)]))
            defer { session.invalidateAndCancel(); AIHTTPFixtureProtocol.registry.remove(token) }
            await assertFailure(expected) { try await self.collect(client, request: self.request(kind)) }
        }
    }

    func testContentTypeAndResponseOriginAreChecked() async throws {
        for fixture in [AIHTTPFixture(contentType: "application/json", chunks: [Data("{}".utf8)]),
                        AIHTTPFixture(chunks: [], responseURL: URL(string: "https://other.example.invalid/v1/chat/completions"))] {
            let (client, session, token) = makeClient(fixture)
            defer { session.invalidateAndCancel(); AIHTTPFixtureProtocol.registry.remove(token) }
            await assertFailure(.invalidResponse) { try await self.collect(client, request: self.request(.openAI)) }
        }
    }

    func testRedirectIsRejectedWithoutFollowingOrResendingKey() async throws {
        let (client, session, token) = makeClient(AIHTTPFixture(status: 307, chunks: [],
                                                              redirectURL: URL(string: "https://other.example.invalid/steal")))
        defer { session.invalidateAndCancel(); AIHTTPFixtureProtocol.registry.remove(token) }
        await assertFailure(.redirectRejected) { try await self.collect(client, request: self.request(.openAI)) }
        let requests = AIHTTPFixtureProtocol.registry.requests(token)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.host, "ai.example.invalid")
    }

    func testCancellationStopsTheTransportAndNeverRetries() async throws {
        let started = expectation(description: "stream started"), stopped = expectation(description: "transport cancelled")
        let fixture = AIHTTPFixture(chunks: [Data(openAIText("SELECT ").utf8)], holdsOpen: true,
                                    didStart: { started.fulfill() }, didStop: { stopped.fulfill() })
        let (client, session, token) = makeClient(fixture)
        defer { session.invalidateAndCancel(); AIHTTPFixtureProtocol.registry.remove(token) }
        let task = Task { try await self.collect(client, request: self.request(.openAI)) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(AIHTTPFixtureProtocol.registry.requests(token).count, 1)
    }

    func testSSEDecoderSupportsCRAndIgnoresCommentsAndUnknownFields() throws {
        var decoder = AISSEDecoder(), events: [AISSEEvent] = []
        let stream = ": keepalive\r\revent: content\rid: 42\rretry: 1000\rdata:first\rdata: second\r\r"
        for byte in stream.utf8 { if let event = try decoder.append(byte) { events.append(event) } }
        XCTAssertEqual(events, [AISSEEvent(name: "content", data: "first\nsecond")])
    }

    func testInvalidUTF8AndOversizedEventAreRejected() throws {
        var invalid = AISSEDecoder()
        for byte in [UInt8(100), 97, 116, 97, 58, 32, 255] { _ = try invalid.append(byte) }
        XCTAssertThrowsError(try invalid.append(10)) { XCTAssertEqual($0 as? AIProviderError, .invalidEvent) }
        var oversized = AISSEDecoder()
        XCTAssertThrowsError(try (0...256 * 1024).forEach { _ in _ = try oversized.append(65) }) {
            XCTAssertEqual($0 as? AIProviderError, .responseTooLarge)
        }
    }

    func testResponseAndOutputBudgetsAreEnforced() async throws {
        let responseOverflow = String(repeating: ":" + String(repeating: "a", count: 65_000) + "\n\n", count: 18)
        let outputOverflow = (0..<6).map { _ in openAIText(String(repeating: "x", count: 100_000)) }.joined()
        for (stream, expected) in [(responseOverflow, AIProviderError.responseTooLarge),
                                   (outputOverflow, AIProviderError.outputTooLarge)] {
            let (client, session, token) = makeClient(AIHTTPFixture(chunks: [Data(stream.utf8)]))
            defer { session.invalidateAndCancel(); AIHTTPFixtureProtocol.registry.remove(token) }
            await assertFailure(expected) { try await self.collect(client, request: self.request(.openAI)) }
        }
    }

    func testInvalidKeyAndOversizedRequestNeverReachTransport() async throws {
        let (client, session, token) = makeClient(AIHTTPFixture(chunks: []))
        defer { session.invalidateAndCancel(); AIHTTPFixtureProtocol.registry.remove(token) }
        let source = request(.openAI)
        let invalid = AIProviderRequest(configuration: source.configuration, apiKey: "bad\nkey",
                                        systemPrompt: source.systemPrompt, messages: source.messages)
        await assertFailure(.invalidAPIKey) { try await self.collect(client, request: invalid) }
        let oversized = AIProviderRequest(configuration: source.configuration, apiKey: source.apiKey,
                                          systemPrompt: source.systemPrompt,
                                          messages: [AIChatMessage(role: .user, content: String(repeating: "a", count: 1024 * 1024))])
        await assertFailure(.requestTooLarge) { try await self.collect(client, request: oversized) }
        XCTAssertTrue(AIHTTPFixtureProtocol.registry.requests(token).isEmpty)
    }

    private func request(_ kind: AIProtocol) -> AIProviderRequest {
        var configuration = AIConfiguration.defaults(for: kind)
        configuration.protocolKind = kind; configuration.baseURL = "https://ai.example.invalid"
        configuration.model = "fixture-model"
        return AIProviderRequest(configuration: configuration, apiKey: "fixture-key", systemPrompt: "Only generate SQL.",
                                 messages: [AIChatMessage(role: .user, content: "List orders"),
                                            AIChatMessage(role: .assistant, content: "SELECT 1;"),
                                            AIChatMessage(role: .user, content: "Use a limit")])
    }

    private func makeClient(_ fixture: AIHTTPFixture) -> (AIHTTPClient, URLSession, UUID) {
        let token = AIHTTPFixtureProtocol.registry.add(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIHTTPFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["X-AI-Fixture": token.uuidString]
        let session = URLSession(configuration: configuration)
        return (AIHTTPClient(session: session), session, token)
    }

    private func collect(_ client: AIHTTPClient, request: AIProviderRequest) async throws -> String {
        var text = ""
        for try await delta in client.stream(request) { text += delta }
        // AsyncThrowingStream is allowed to finish normally when its consuming
        // task is cancelled. The caller must not treat that EOF as completion.
        try Task.checkCancellation()
        return text
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }; result.append(contentsOf: buffer.prefix(count))
            }
            data = result
        } else { throw AIProviderError.invalidResponse }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertFailure(_ expected: AIProviderError, operation: () async throws -> String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AIProviderError, expected, file: file, line: line) }
    }

    private var openAIFinish: String { "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" }
    private func openAIText(_ text: String) -> String {
        let object: [String: Any] = ["choices": [["delta": ["content": text], "finish_reason": NSNull()]]]
        return "data: " + String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n\n"
    }
    private func anthropicEvent(_ type: String, _ fields: [String: Any]) -> String {
        var object = fields; object["type"] = type
        return "event: \(type)\ndata: " + String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n\n"
    }
}

private struct AIHTTPFixture {
    var status = 200
    var contentType = "text/event-stream; charset=utf-8"
    var chunks: [Data]
    var responseURL: URL?
    var redirectURL: URL?
    var holdsOpen = false
    var didStart: (() -> Void)?
    var didStop: (() -> Void)?
}

private final class AIHTTPFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [UUID: AIHTTPFixture] = [:]
    private var captured: [UUID: [URLRequest]] = [:]
    func add(_ fixture: AIHTTPFixture) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID(); fixtures[token] = fixture; return token
    }
    func fixture(_ token: UUID, request: URLRequest) -> AIHTTPFixture? {
        lock.lock(); defer { lock.unlock() }
        captured[token, default: []].append(request); return fixtures[token]
    }
    func requests(_ token: UUID) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return captured[token] ?? []
    }
    func remove(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }; fixtures.removeValue(forKey: token); captured.removeValue(forKey: token)
    }
}

private final class AIHTTPFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let registry = AIHTTPFixtureRegistry()
    private var didStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let value = request.value(forHTTPHeaderField: "X-AI-Fixture"), let token = UUID(uuidString: value),
              let fixture = Self.registry.fixture(token, request: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        didStop = fixture.didStop
        let response = HTTPURLResponse(url: fixture.responseURL ?? url, statusCode: fixture.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": fixture.contentType])!
        if let redirect = fixture.redirectURL {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in fixture.chunks { client?.urlProtocol(self, didLoad: chunk) }
        fixture.didStart?()
        if !fixture.holdsOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { didStop?(); didStop = nil }
}
