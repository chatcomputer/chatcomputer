import Foundation

/// One model turn: the raw assistant content plus what the orchestrator needs from it.
public struct ModelResponse: Sendable, Equatable {
    /// Raw `content` array; appended to the conversation unchanged.
    public var content: [JSONValue]
    public var stopReason: String?
    public var inputTokens: Int
    public var outputTokens: Int
    /// The model that actually served the turn (differs from the request after a fallback).
    public var servedModel: String?

    public init(content: [JSONValue], stopReason: String?, inputTokens: Int, outputTokens: Int, servedModel: String?) {
        self.content = content
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
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
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case badRequest(String)
    case server(status: Int, message: String)
    case refused(category: String?)
    case network(String)
    case malformedResponse
}

public protocol ModelClient: Sendable {
    var modelID: String { get }
    func respond(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ModelResponse
}
