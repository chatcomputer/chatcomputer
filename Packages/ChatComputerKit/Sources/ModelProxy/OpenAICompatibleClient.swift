import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI-compatible Chat Completions (`POST {base}/chat/completions`), the protocol most model
/// vendors offer. The orchestrator keeps working in Claude's content-block shape; this client
/// translates in both directions:
///
/// - the computer toolset becomes one `computer` function (see `CompatibleDialect`), host tools
///   become functions, `tool_use` blocks become `tool_calls`, and `tool_result` blocks become
///   `role: "tool"` messages;
/// - screenshots in tool results go into a user message right after the tool messages, because
///   Chat Completions tool messages carry text only;
/// - responses come back as `text` and `tool_use` blocks. Vendor fields that must be echoed on
///   later turns are kept on our side and sent back unchanged: `reasoning_content` (DeepSeek, Kimi
///   and Zhipu require it on tool-calling turns) and per-call `extra_content` (Gemini's thought
///   signature). Nothing is echoed that the vendor did not send;
/// - only the most recent screenshots are sent (`maxImages`); older ones become a short note.
///   This keeps requests small and within vendor limits (Mistral: 8 images per request).
public struct OpenAICompatibleClient: ModelClient {
    public struct Configuration: Sendable {
        public var model: String
        public var maxTokens: Int
        /// e.g. `https://api.openai.com/v1`; the request goes to `{baseURL}/chat/completions`.
        public var baseURL: URL
        /// OpenAI's own API wants `max_completion_tokens`; most compatible vendors want `max_tokens`.
        public var usesMaxCompletionTokens: Bool
        /// Guest screen size in points, described to the model in the `computer` tool.
        public var displayWidth: Int
        public var displayHeight: Int
        /// Screenshots sent per request, newest first.
        public var maxImages: Int

        public init(model: String, baseURL: URL, maxTokens: Int = 8_000, usesMaxCompletionTokens: Bool = false,
                    displayWidth: Int = 1280, displayHeight: Int = 800, maxImages: Int = 3) {
            self.model = model
            self.maxImages = maxImages
            self.baseURL = baseURL
            self.maxTokens = maxTokens
            self.usesMaxCompletionTokens = usesMaxCompletionTokens
            self.displayWidth = displayWidth
            self.displayHeight = displayHeight
        }

        public var endpoint: URL { baseURL.appendingPathComponent("chat/completions") }
    }

    public let configuration: Configuration
    private let apiKey: @Sendable () throws -> String?
    private let session: URLSession

    public var modelID: String { configuration.model }

    public init(configuration: Configuration, session: URLSession = .shared, apiKey: @escaping @Sendable () throws -> String?) {
        self.configuration = configuration
        self.session = session
        self.apiKey = apiKey
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

    // MARK: Request

    public func makeRequest(system: String, tools: [JSONValue], messages: [JSONValue]) throws -> URLRequest {
        guard let key = try apiKey(), !key.isEmpty else { throw ModelError.missingAPIKey }

        var body: [String: JSONValue] = [
            "model": .string(configuration.model),
            "messages": .array(Self.chatMessages(system: system, messages: CompatibleDialect.keepingRecentImages(messages, limit: configuration.maxImages))),
        ]
        body[configuration.usesMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = .number(Double(configuration.maxTokens))
        let functions = Self.functions(from: tools, displayWidth: configuration.displayWidth, displayHeight: configuration.displayHeight)
        if !functions.isEmpty { body["tools"] = .array(functions) }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.httpBody = try StableJSON.encoder.encode(JSONValue.object(body))
        return request
    }

    static func functions(from tools: [JSONValue], displayWidth: Int, displayHeight: Int) -> [JSONValue] {
        CompatibleDialect.requestTools(tools, displayWidth: displayWidth, displayHeight: displayHeight).compactMap { tool in
            guard let name = tool["name"] else { return nil }
            return [
                "type": "function",
                "function": [
                    "name": name,
                    "description": tool["description"] ?? "",
                    "parameters": tool["input_schema"] ?? ["type": "object"],
                ],
            ]
        }
    }

    /// Claude-shaped history → Chat Completions messages.
    static func chatMessages(system: String, messages: [JSONValue]) -> [JSONValue] {
        var result: [JSONValue] = [["role": "system", "content": .string(system)]]
        for message in CompatibleDialect.requestMessages(messages) {
            let role = message["role"]?.stringValue ?? "user"
            guard let blocks = message["content"]?.arrayValue else {
                result.append(["role": .string(role), "content": message["content"] ?? ""])
                continue
            }
            if role == "assistant" {
                result.append(assistantMessage(blocks))
            } else {
                result.append(contentsOf: userMessages(blocks))
            }
        }
        return result
    }

    private static func assistantMessage(_ blocks: [JSONValue]) -> JSONValue {
        var text: [String] = []
        var calls: [JSONValue] = []
        var reasoning: String?
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                if let value = block["text"]?.stringValue, !value.isEmpty { text.append(value) }
            case "tool_use":
                let arguments = (try? String(decoding: StableJSON.encoder.encode(block["input"] ?? [:]), as: UTF8.self)) ?? "{}"
                var call: [String: JSONValue] = [
                    "id": block["id"] ?? "",
                    "type": "function",
                    "function": ["name": block["name"] ?? "", "arguments": .string(arguments)],
                ]
                if let extra = block[Self.extraKey] { call["extra_content"] = extra }
                calls.append(.object(call))
            case Self.reasoningType:
                reasoning = block["reasoning_content"]?.stringValue
            default:
                continue   // Claude thinking blocks stay on our side
            }
        }
        var message: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text.joined(separator: "\n"))]
        if !calls.isEmpty { message["tool_calls"] = .array(calls) }
        if let reasoning { message["reasoning_content"] = .string(reasoning) }
        return .object(message)
    }

    /// Our block type for a vendor's `reasoning_content`; the orchestrator ignores unknown block types.
    static let reasoningType = "openai_reasoning"
    /// Key on a `tool_use` block holding the call's vendor `extra_content`.
    static let extraKey = "openai_extra_content"

    /// Tool results first (they must follow the assistant's tool calls directly), then one user
    /// message with the remaining text and every image, including screenshots from tool results.
    private static func userMessages(_ blocks: [JSONValue]) -> [JSONValue] {
        var toolMessages: [JSONValue] = []
        var parts: [JSONValue] = []

        func imagePart(_ block: JSONValue) -> JSONValue? {
            guard let source = block["source"], let data = source["data"]?.stringValue else { return nil }
            let mediaType = source["media_type"]?.stringValue ?? "image/png"
            return ["type": "image_url", "image_url": ["url": .string("data:\(mediaType);base64,\(data)")]]
        }

        for block in blocks {
            switch block["type"]?.stringValue {
            case "tool_result":
                var texts: [String] = []
                var images = 0
                if let content = block["content"]?.arrayValue {
                    for item in content {
                        if item["type"] == "text", let value = item["text"]?.stringValue { texts.append(value) }
                        if item["type"] == "image", let part = imagePart(item) {
                            parts.append(part)
                            images += 1
                        }
                    }
                } else if let value = block["content"]?.stringValue {
                    texts.append(value)
                }
                if images > 0 { texts.append("Screenshot attached in the next message.") }
                if block["is_error"] == true { texts.insert("Error:", at: 0) }
                toolMessages.append([
                    "role": "tool",
                    "tool_call_id": block["tool_use_id"] ?? "",
                    "content": .string(texts.isEmpty ? "OK" : texts.joined(separator: " ")),
                ])
            case "text":
                parts.append(["type": "text", "text": block["text"] ?? ""])
            case "image":
                if let part = imagePart(block) { parts.append(part) }
            default:
                continue
            }
        }
        if !parts.isEmpty {
            if !toolMessages.isEmpty, !parts.contains(where: { $0["type"] == "text" }) {
                parts.insert(["type": "text", "text": "Current screen:"], at: 0)
            }
            toolMessages.append(["role": "user", "content": .array(parts)])
        }
        return toolMessages
    }

    // MARK: Response

    static func parse(status: Int, retryAfter: String?, body: Data) throws -> ModelResponse {
        let json = (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .null
        let message = json["error"]?["message"]?.stringValue ?? String(decoding: body.prefix(500), as: UTF8.self)
        switch status {
        case 200: break
        case 401, 403: throw ModelError.authentication(message)
        case 429: throw ModelError.rateLimited(retryAfter: retryAfter.flatMap(TimeInterval.init))
        case 529, 503: throw ModelError.overloaded
        case 400..<500: throw ModelError.badRequest(message)
        default: throw ModelError.server(status: status, message: message)
        }

        guard let choice = json["choices"]?.arrayValue?.first, let reply = choice["message"] else { throw ModelError.malformedResponse }
        var content: [JSONValue] = []
        if let reasoning = reply["reasoning_content"]?.stringValue, !reasoning.isEmpty {
            content.append(["type": .string(reasoningType), "reasoning_content": .string(reasoning)])
        }
        if let text = reply["content"]?.stringValue, !text.isEmpty {
            content.append(["type": "text", "text": .string(text)])
        }
        for (index, call) in (reply["tool_calls"]?.arrayValue ?? []).enumerated() {
            let function = call["function"]
            let raw = function?["arguments"]?.stringValue ?? "{}"
            let input = (try? JSONDecoder().decode(JSONValue.self, from: Data((raw.isEmpty ? "{}" : raw).utf8))) ?? [:]
            let id = call["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(index)_\(UUID().uuidString.prefix(8))"
            var block: [String: JSONValue] = ["type": "tool_use", "id": .string(id), "name": function?["name"] ?? "", "input": input]
            if let extra = call["extra_content"] { block[extraKey] = extra }
            content.append(.object(block))
        }

        let stopReason: String? = switch choice["finish_reason"]?.stringValue {
        case "tool_calls", "function_call": "tool_use"
        case "length": "max_tokens"
        case "content_filter": "refusal"
        case .some(let other): other == "stop" ? "end_turn" : other
        case .none: nil
        }
        if stopReason == "refusal" { throw ModelError.refused(category: "content_filter") }

        return ModelResponse(
            content: CompatibleDialect.responseContent(content),
            stopReason: stopReason,
            inputTokens: json["usage"]?["prompt_tokens"]?.intValue ?? 0,
            outputTokens: json["usage"]?["completion_tokens"]?.intValue ?? 0,
            servedModel: json["model"]?.stringValue
        )
    }
}
