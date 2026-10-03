import Foundation

/// Request/response translation for Anthropic-compatible endpoints that lack Claude's server-side
/// computer toolset (e.g. DeepSeek's `/anthropic` endpoint). Used for development and testing only.
///
/// The orchestrator keeps working in the toolset shape (`tool_use.name` = action,
/// `toolset_name` = "computer"). On the wire, the toolset becomes one custom `computer` tool
/// whose input carries the action, and Claude-only request fields are dropped.
public enum CompatibleDialect {
    public static let toolName = "computer"

    static let actions: [JSONValue] = [
        "screenshot", "zoom", "left_click", "right_click", "middle_click", "double_click", "triple_click",
        "left_click_drag", "mouse_move", "left_mouse_down", "left_mouse_up", "cursor_position",
        "scroll", "type", "key", "hold_key", "wait",
    ]

    static func computerTool(displayWidth: Int, displayHeight: Int) -> JSONValue {
        let point: JSONValue = ["type": "array", "items": ["type": "integer"], "minItems": 2, "maxItems": 2]
        return [
            "name": .string(toolName),
            "description": .string("""
                Control the macOS desktop. The screen is \(displayWidth)x\(displayHeight) points; coordinates are \
                [x, y] in that space, origin top-left. Take a screenshot first and after each change to see the result. \
                `key` takes combos like "cmd+s" or "return"; `type` types literal text.
                """),
            "input_schema": [
                "type": "object",
                "required": ["action"],
                "properties": [
                    "action": ["type": "string", "enum": .array(actions)],
                    "coordinate": point,
                    "start_coordinate": point,
                    "region": ["type": "array", "items": ["type": "integer"], "description": "[x0, y0, x1, y1] for zoom"],
                    "text": ["type": "string", "description": "Text to type, key combo, or modifiers held during a click"],
                    "scroll_direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "scroll_amount": ["type": "integer"],
                    "duration": ["type": "number"],
                    "repeat": ["type": "integer"],
                ],
            ],
        ]
    }

    /// Rewrites the tool list and history from toolset shape to the single custom tool.
    static func requestTools(_ tools: [JSONValue], displayWidth: Int, displayHeight: Int) -> [JSONValue] {
        tools.map { tool in
            tool["type"] == ComputerToolset.definition["type"] ? computerTool(displayWidth: displayWidth, displayHeight: displayHeight) : tool
        }
    }

    static func requestMessages(_ messages: [JSONValue]) -> [JSONValue] {
        messages.map { message in
            guard case .object(var object) = message, let content = object["content"]?.arrayValue else { return message }
            object["content"] = .array(content.map(outgoingBlock))
            return .object(object)
        }
    }

    private static func outgoingBlock(_ block: JSONValue) -> JSONValue {
        guard case .object(var object) = block else { return block }
        switch object["type"]?.stringValue {
        case "tool_use" where object["toolset_name"]?.stringValue == ComputerToolset.toolsetName:
            object["toolset_name"] = nil
            var input: [String: JSONValue] = [:]
            if case .object(let original) = object["input"] ?? [:] { input = original }
            input["action"] = object["name"]
            object["name"] = .string(toolName)
            object["input"] = .object(input)
        case "tool_result":
            object["toolset_name"] = nil
        default:
            break
        }
        return .object(object)
    }

    static func imageCount(_ value: JSONValue) -> Int {
        if value["type"] == "image" { return 1 }
        return (value["content"]?.arrayValue ?? []).reduce(0) { $0 + imageCount($1) }
    }

    /// Rewrites `computer` tool calls in a response back into toolset shape.
    static func responseContent(_ content: [JSONValue]) -> [JSONValue] {
        content.map { block in
            guard case .object(var object) = block, object["type"] == "tool_use", object["name"]?.stringValue == toolName,
                  case .object(var input) = object["input"] ?? [:], let action = input["action"]?.stringValue else { return block }
            input["action"] = nil
            object["name"] = .string(action)
            object["toolset_name"] = .string(ComputerToolset.toolsetName)
            object["input"] = .object(input)
            return .object(object)
        }
    }

    /// Replaces older images in the history with a text note, keeping at least the newest `limit`.
    /// Only for endpoints other than Claude's own (Claude keeps history unchanged; see AgentRunner).
    ///
    /// Images are removed `batch` at a time, so between removals the history sent is the previous request
    /// plus new turns, and the provider's prefix cache (DeepSeek, OpenAI, …) keeps hitting. Removing the oldest
    /// image every turn would change the prefix on every request.
    public static func keepingRecentImages(_ messages: [JSONValue], limit: Int, batch: Int = 4) -> [JSONValue] {
        let total = messages.reduce(0) { $0 + imageCount($1) }
        let batch = max(batch, 1)
        let removed = total > limit ? ((total - limit) / batch) * batch : 0
        var remaining = total - removed
        let note: JSONValue = ["type": "text", "text": "[Earlier screenshot removed to save space.]"]

        func trim(_ block: JSONValue) -> JSONValue {
            guard case .object(var object) = block else { return block }
            if object["type"] == "image" {
                if remaining > 0 { remaining -= 1; return block }
                return note
            }
            if object["type"] == "tool_result", let content = object["content"]?.arrayValue {
                object["content"] = .array(content.reversed().map(trim).reversed())
                return .object(object)
            }
            return block
        }

        // Walk newest to oldest so the most recent images are the ones kept.
        return messages.reversed().map { message -> JSONValue in
            guard case .object(var object) = message, let content = object["content"]?.arrayValue else { return message }
            object["content"] = .array(content.reversed().map(trim).reversed())
            return .object(object)
        }.reversed()
    }
}
