import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude Messages API over raw HTTP (there is no official Swift SDK).
///
/// Requests go out from the host only; the key never enters the guest (proposal §03).
public struct AnthropicClient: ModelClient {
    public struct Configuration: Sendable {
        public enum Dialect: Sendable, Equatable {
            /// Claude Messages API with the server-side computer toolset.
            case claude
            /// Anthropic-compatible endpoint without the toolset (see `CompatibleDialect`); development only.
            case compatible(displayWidth: Int, displayHeight: Int)
        }

        public var model: String
        public var effort: String
        public var maxTokens: Int
        public var endpoint: URL
        public var dialect: Dialect

        public init(
            model: String = "claude-opus-5-5",
            effort: String = "medium",
            maxTokens: Int = 16_000,
            endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
            dialect: Dialect = .claude
        ) {
            self.model = model
            self.effort = effort
            self.maxTokens = maxTokens
            self.endpoint = endpoint
            self.dialect = dialect
        }
    }

    /// Server-side refusal fallback and progress-note summaries between tool calls.
    static let betaHeaders = ["server-side-fallback-2026-07-01", "thinking-display-updates-2026-08-18"]

    public let configuration: Configuration
    private let apiKey: @Sendable () throws -> String?
    private let session: URLSession
    private let streaming = StreamingSupport()

    public var modelID: String { configuration.model }

    public init(configuration: Configuration = .init(), session: URLSession = .shared, apiKey: @escaping @Sendable () throws -> String?) {
        self.configuration = configuration
        self.session = session
        self.apiKey = apiKey
    }

    public func makeRequest(system: String, tools: [JSONValue], messages: [JSONValue], stream: Bool = false) throws -> URLRequest {
        guard let key = try apiKey(), !key.isEmpty else { throw ModelError.missingAPIKey }

        if case .compatible(let width, let height) = configuration.dialect {
            let body: JSONValue = [
                "model": .string(configuration.model),
                "max_tokens": .number(Double(configuration.maxTokens)),
                "system": .string(system),
                "tools": .array(CompatibleDialect.requestTools(tools, displayWidth: width, displayHeight: height)),
                "messages": .array(CompatibleDialect.requestMessages(CompatibleDialect.keepingRecentImages(messages, limit: 3))),
            ]
            guard case .object(var object) = body else { return try request(body: body, key: key, betas: []) }
            // Some compatible endpoints reject an empty tool list (e.g. a connection test without tools).
            if tools.isEmpty { object["tools"] = nil }
            if stream { object["stream"] = true }
            return try request(body: .object(object), key: key, betas: [])
        }

        let body: JSONValue = [
            "model": .string(configuration.model),
            "max_tokens": .number(Double(configuration.maxTokens)),
            "system": .string(system),
            "tools": .array(tools),
            "messages": .array(messages),
            "thinking": ["type": "adaptive", "display": "updates"],
            "output_config": ["effort": .string(configuration.effort)],
            // Automatic prompt caching: the conversation grows append-only, so each turn reuses the prefix.
            "cache_control": ["type": "ephemeral"],
            "fallbacks": "default",
        ]
        guard stream, case .object(var object) = body else { return try request(body: body, key: key, betas: Self.betaHeaders) }
        object["stream"] = true
        return try request(body: .object(object), key: key, betas: Self.betaHeaders)
    }

    private func request(body: JSONValue, key: String, betas: [String]) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty { request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.httpBody = try StableJSON.encoder.encode(body)
        return request
    }

    public func respond(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ModelResponse {
        let request = try makeRequest(system: system, tools: tools, messages: messages)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ModelError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ModelError.malformedResponse }
        var parsed = try Self.parse(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "retry-after"), body: data)
        if case .compatible = configuration.dialect {
            parsed.content = CompatibleDialect.responseContent(parsed.content)
        }
        return parsed
    }

    public func respond(system: String, tools: [JSONValue], messages: [JSONValue], onText: PartialTextHandler?) async throws -> ModelResponse {
        guard let onText, streaming.enabled else { return try await respond(system: system, tools: tools, messages: messages) }
        let opened = try await StreamTransport.open(try makeRequest(system: system, tools: tools, messages: messages, stream: true), session: session)
        guard opened.status == 200 else {
            let body = await StreamTransport.collect(opened.lines)
            do {
                _ = try Self.parse(status: opened.status, retryAfter: opened.retryAfter, body: body)
                throw ModelError.malformedResponse
            } catch where StreamingSupport.isRefusal(error) {
                streaming.refuse()
                return try await respond(system: system, tools: tools, messages: messages)
            }
        }
        var events = ServerSentEvents()
        var assembler = AnthropicStreamAssembler()
        var throttle = PartialThrottle()
        for try await line in opened.lines {
            guard let event = events.feed(line) else { continue }
            if try assembler.apply(event), throttle.due() { onText(assembler.currentText) }
        }
        if let event = events.flush() { _ = try assembler.apply(event) }
        if let error = assembler.error { throw ModelError.fromStreamError(error) }
        let body = assembler.body()
        // A stream that stopped before the message did would leave a tool call half written: send it again.
        guard body["stop_reason"] != nil, body["stop_reason"] != .null else { throw ModelError.network("The response stream ended early.") }
        var parsed = try Self.parse(status: 200, retryAfter: nil, body: try StableJSON.encoder.encode(body))
        if case .compatible = configuration.dialect {
            parsed.content = CompatibleDialect.responseContent(parsed.content)
        }
        return parsed
    }

    static func parse(status: Int, retryAfter: String?, body: Data) throws -> ModelResponse {
        let json = (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .null
        let message = json["error"]?["message"]?.stringValue ?? String(decoding: body.prefix(500), as: UTF8.self)

        if status != 200, ModelError.isBilling(status: status, message: message, code: json["error"]?["code"]?.stringValue) {
            throw ModelError.billing(message)
        }
        switch status {
        case 200:
            break
        case 401, 403:
            throw ModelError.authentication(message)
        case 429:
            throw ModelError.rateLimited(retryAfter: retryAfter.flatMap(TimeInterval.init))
        case 529:
            throw ModelError.overloaded
        case 400..<500:
            throw ModelError.badRequest(message)
        default:
            throw ModelError.server(status: status, message: message)
        }

        guard let content = json["content"]?.arrayValue else { throw ModelError.malformedResponse }
        let stopReason = json["stop_reason"]?.stringValue
        if stopReason == "refusal" {
            throw ModelError.refused(category: json["stop_details"]?["category"]?.stringValue)
        }
        return ModelResponse(
            content: content,
            stopReason: stopReason,
            // Anthropic's input_tokens excludes cache reads and writes; count them all as input.
            inputTokens: (json["usage"]?["input_tokens"]?.intValue ?? 0) + (json["usage"]?["cache_read_input_tokens"]?.intValue ?? 0)
                + (json["usage"]?["cache_creation_input_tokens"]?.intValue ?? 0),
            outputTokens: json["usage"]?["output_tokens"]?.intValue ?? 0,
            cachedInputTokens: json["usage"]?["cache_read_input_tokens"]?.intValue ?? 0,
            servedModel: json["model"]?.stringValue
        )
    }
}
