import Foundation

/// One model turn: the raw assistant content plus what the orchestrator needs from it.
public struct ModelResponse: Sendable, Equatable {
    /// Raw `content` array; appended to the conversation unchanged.
    public var content: [JSONValue]
    public var stopReason: String?
    public var inputTokens: Int
    public var outputTokens: Int
    /// Of `inputTokens`, how many the provider served from its prompt cache (billed at a fraction).
    public var cachedInputTokens: Int
    /// The model that actually served the turn (differs from the request after a fallback).
    public var servedModel: String?

    /// `inputTokens` counts every input token, cached or not.
    public init(content: [JSONValue], stopReason: String?, inputTokens: Int, outputTokens: Int, cachedInputTokens: Int = 0, servedModel: String?) {
        self.content = content
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.servedModel = servedModel
    }

    public var blocks: [ContentBlock] { content.map(ContentBlock.init) }
}

public enum ContentBlock: Sendable, Equatable {
    case text(String)
    /// Progress notes between tool calls arrive as thinking blocks (`display: "updates"`).
    case thinking(String)
    case toolUse(id: String, name: String, toolsetName: String?, input: JSONValue)
    case other

    init(_ json: JSONValue) {
        switch json["type"]?.stringValue {
        case "text":
            self = .text(json["text"]?.stringValue ?? "")
        case "thinking":
            self = .thinking(json["thinking"]?.stringValue ?? "")
        case "tool_use":
            self = .toolUse(
                id: json["id"]?.stringValue ?? "",
                name: json["name"]?.stringValue ?? "",
                toolsetName: json["toolset_name"]?.stringValue,
                input: json["input"] ?? .object([:])
            )
        default:
            self = .other
        }
    }
}

/// Model errors are kept separate from desktop errors so the UI can tell
/// "your API key is wrong" apart from "the VM didn't respond" (proposal §03).
public enum ModelError: Error, Equatable {
    case missingAPIKey
    case authentication(String)
    /// The provider account has no credit or quota left.
    case billing(String)
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case badRequest(String)
    case server(status: Int, message: String)
    case refused(category: String?)
    case network(String)
    case malformedResponse
}

extension ModelError {
    /// Worth sending the same request again after a pause: the provider or the network, not the request.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded, .network: true
        case .server(let status, _): status >= 500
        default: false
        }
    }

    /// The user can fix it and continue the task: a missing or rejected key, or a provider still failing
    /// after the retries. A malformed or refused request would fail the same way again.
    public var userCanFix: Bool {
        switch self {
        case .missingAPIKey, .authentication, .billing: true
        default: isTransient
        }
    }

    /// Providers report an empty account in different ways: 402 (DeepSeek), 429 with insufficient_quota (OpenAI),
    /// 400 "credit balance is too low" (Anthropic). Retrying or failing the task would both be wrong.
    public static func isBilling(status: Int, message: String, code: String?) -> Bool {
        if status == 402 || code == "insufficient_quota" { return true }
        let text = message.lowercased()
        return ["credit balance", "insufficient balance", "insufficient_quota", "exceeded your current quota", "billing"]
            .contains { text.contains($0) }
    }

    /// One sentence for the chat.
    public var explanation: String {
        switch self {
        case .missingAPIKey: "No API key is set for this model. Add it in Settings › Model."
        case .authentication(let message): "The model provider rejected the API key (\(message)). Check it in Settings › Model."
        case .billing(let message): "The model provider account is out of credit (\(message)). Add credit with the provider, then continue."
        case .rateLimited: "The model provider is rate-limiting requests."
        case .overloaded: "The model provider is overloaded."
        case .server(let status, let message): "The model provider returned an error (\(status): \(message))."
        case .network(let message): "Could not reach the model provider (\(message)). Check the internet connection."
        case .badRequest(let message): "The model provider rejected the request: \(message)"
        case .refused(let category): "The model declined to continue" + (category.map { " (\($0))" } ?? "") + "."
        case .malformedResponse: "The model provider sent a response Chat Computer could not read."
        }
    }
}

public protocol ModelClient: Sendable {
    var modelID: String { get }
    func respond(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ModelResponse
}
