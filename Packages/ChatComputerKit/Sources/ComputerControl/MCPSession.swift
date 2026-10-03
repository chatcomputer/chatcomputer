import Foundation
import ModelProxy

/// A request from the `chatcomputer` tool (or its MCP server) to the app, one JSON line per connection.
public struct ControlRequest: Codable, Sendable, Equatable {
    public var command: String
    public var arguments: [String: JSONValue]
    /// Who is asking, e.g. "Claude Code"; shown to the user while it controls the virtual Mac.
    public var client: String

    public init(command: String, arguments: [String: JSONValue] = [:], client: String) {
        self.command = command
        self.arguments = arguments
        self.client = client
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public var text: String
    public var isError: Bool
    /// A screenshot (base64 in JSON).
    public var image: Data?
    public var imageType: String?

    public init(text: String, isError: Bool = false, image: Data? = nil, imageType: String? = nil) {
        self.text = text
        self.isError = isError
        self.image = image
        self.imageType = imageType
    }

    public static func error(_ text: String) -> ControlResponse { ControlResponse(text: text, isError: true) }
}

/// MCP (JSON-RPC 2.0 over newline-delimited stdio) in front of the control commands.
///
/// It handles `initialize`, `ping`, `tools/list` and `tools/call`; each tool call becomes a
/// `ControlRequest` that `forward` sends to the app.
public final class MCPSession: @unchecked Sendable {
    public typealias Forward = @Sendable (ControlRequest) async -> ControlResponse

    private let forward: Forward
    private let serverVersion: String
    private var clientName = "MCP client"

    public init(serverVersion: String, forward: @escaping Forward) {
        self.serverVersion = serverVersion
        self.forward = forward
    }

    /// Handles one incoming message; returns the line to write back, or nil for notifications.
    public func handle(_ line: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line), case .object(let fields) = message else {
            return Self.encode(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let method = fields["method"]?.stringValue else { return nil }   // a response to us; we send no requests
        guard let id = fields["id"] else { return nil }                        // notification
        let params = fields["params"] ?? [:]
        do {
            let result = try await respond(method: method, params: params)
            return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as RPCError {
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]])
        } catch {
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": .string("\(error)")]])
        }
    }

    private func respond(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            if let name = params["clientInfo"]?["name"]?.stringValue, !name.isEmpty { clientName = Self.displayName(name) }
            return [
                "protocolVersion": .string(params["protocolVersion"]?.stringValue ?? "2025-06-18"),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "chatcomputer", "version": .string(serverVersion)],
                "instructions": .string(ControlGuide.text),
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(ControlTool.all.map { ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema] })]
        case "tools/call":
            guard let name = params["name"]?.stringValue else { throw RPCError(code: -32602, message: "tools/call needs a name") }
            guard ControlTool.all.contains(where: { $0.name == name }) else { throw RPCError(code: -32602, message: "Unknown tool: \(name)") }
            let arguments: [String: JSONValue] = if case .object(let object)? = params["arguments"] { object } else { [:] }
            let response = await forward(ControlRequest(command: name, arguments: arguments, client: clientName))
            var content: [JSONValue] = []
            if let image = response.image {
                content.append(["type": "image", "data": .string(image.base64EncodedString()), "mimeType": .string(response.imageType ?? "image/png")])
            }
            content.append(["type": "text", "text": .string(response.text)])
            return ["content": .array(content), "isError": .bool(response.isError)]
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    /// "claude-code" → "Claude Code", so the user sees a readable name.
    static func displayName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "claude-code", "claude code": "Claude Code"
        case "codex", "codex-mcp-client", "codex_mcp_client": "Codex"
        case "cursor", "cursor-vscode": "Cursor"
        case "gemini-cli-mcp-client", "gemini-cli": "Gemini CLI"
        default: raw
        }
    }

    private static func encode(_ value: JSONValue) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private struct RPCError: Error {
        let code: Int
        let message: String
    }
}
