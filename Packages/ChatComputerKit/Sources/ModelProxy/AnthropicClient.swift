import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude Messages API over raw HTTP (there is no official Swift SDK).
///
/// Requests go out from the host only; the key never enters the guest (proposal §03).
public struct AnthropicClient: ModelClient {
    public struct Configuration: Sendable {
        public var model: String
        public var effort: String
        public var maxTokens: Int
        public var endpoint: URL

        public init(
            model: String = "claude-opus-5-5",
            effort: String = "medium",
            maxTokens: Int = 16_000,
            endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
        ) {
            self.model = model
            self.effort = effort
            self.maxTokens = maxTokens
            self.endpoint = endpoint
        }
    }

    /// Server-side refusal fallback and progress-note summaries between tool calls.
    static let betaHeaders = ["server-side-fallback-2026-07-01", "thinking-display-updates-2026-08-18"]

    public let configuration: Configuration
    private let apiKey: @Sendable () throws -> String?
    private let session: URLSession

    public var modelID: String { configuration.model }

    public init(configuration: Configuration = .init(), session: URLSession = .shared, apiKey: @escaping @Sendable () throws -> String?) {
        self.configuration = configuration
        self.session = session
        self.apiKey = apiKey
    }

    public func makeRequest(system: String, tools: [JSONValue], messages: [JSONValue]) throws -> URLRequest {
        guard let key = try apiKey(), !key.isEmpty else { throw ModelError.missingAPIKey }

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

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.betaHeaders.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
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
        return try Self.parse(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "retry-after"), body: data)
    }

    static func parse(status: Int, retryAfter: String?, body: Data) throws -> ModelResponse {
        let json = (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .null
        let message = json["error"]?["message"]?.stringValue ?? String(decoding: body.prefix(500), as: UTF8.self)

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
            inputTokens: json["usage"]?["input_tokens"]?.intValue ?? 0,
            outputTokens: json["usage"]?["output_tokens"]?.intValue ?? 0,
            servedModel: json["model"]?.stringValue
        )
    }
}
