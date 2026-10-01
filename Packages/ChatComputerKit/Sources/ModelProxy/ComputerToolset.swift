import Foundation
import BridgeProtocol

/// Mapping between Claude's computer toolset (`computer_toolset_20260801`) and `GuestCommand`.
///
/// Each member tool arrives as its own `tool_use` block whose `name` is the action and whose
/// `toolset_name` is "computer". Every result must echo `toolset_name`.
public enum ComputerToolset {
    public static let toolsetName = "computer"

    public static let definition: JSONValue = [
        "type": "computer_toolset_20260801",
    ]

    public struct InvalidInput: Error, Equatable, CustomStringConvertible {
        public let tool: String
        public let detail: String
        public var description: String { "\(tool): \(detail)" }
    }

    /// Translates one member call into a guest command.
    public static func command(name: String, input: JSONValue) throws -> GuestCommand {
        func point(_ key: String) throws -> ScreenPoint? {
            guard let value = input[key] else { return nil }
            guard let pair = value.arrayValue, pair.count == 2,
                  let x = pair[0].intValue, let y = pair[1].intValue else {
                throw InvalidInput(tool: name, detail: "\(key) must be [x, y]")
            }
            return ScreenPoint(x: x, y: y)
        }
        func required(_ key: String) throws -> ScreenPoint {
            guard let value = try point(key) else { throw InvalidInput(tool: name, detail: "missing \(key)") }
            return value
        }
        func text(_ key: String = "text") throws -> String {
            guard let value = input[key]?.stringValue else { throw InvalidInput(tool: name, detail: "missing \(key)") }
            return value
        }
        let modifiers = input["text"]?.stringValue.map(Self.modifiers) ?? []

        switch name {
        case "screenshot":
            return .screenshot(region: nil)
        case "zoom":
            guard let values = input["region"]?.arrayValue?.compactMap(\.intValue), values.count == 4 else {
                throw InvalidInput(tool: name, detail: "region must be [x0, y0, x1, y1]")
            }
            return .screenshot(region: ScreenRect(x0: values[0], y0: values[1], x1: values[2], y1: values[3]))
        case "left_click":
            return .perform(.click(button: .left, count: 1, at: try point("coordinate"), modifiers: modifiers))
        case "right_click":
            return .perform(.click(button: .right, count: 1, at: try point("coordinate"), modifiers: modifiers))
        case "middle_click":
            return .perform(.click(button: .middle, count: 1, at: try point("coordinate"), modifiers: modifiers))
        case "double_click":
            return .perform(.click(button: .left, count: 2, at: try point("coordinate"), modifiers: modifiers))
        case "triple_click":
            return .perform(.click(button: .left, count: 3, at: try point("coordinate"), modifiers: modifiers))
        case "left_click_drag":
            return .perform(.drag(from: try required("start_coordinate"), to: try required("coordinate"), modifiers: modifiers))
        case "mouse_move":
            return .perform(.mouseMove(to: try required("coordinate")))
        case "left_mouse_down":
            return .perform(.mouseDown)
        case "left_mouse_up":
            return .perform(.mouseUp)
        case "cursor_position":
            return .perform(.cursorPosition)
        case "scroll":
            guard let raw = input["scroll_direction"]?.stringValue, let direction = ScrollDirection(rawValue: raw) else {
                throw InvalidInput(tool: name, detail: "scroll_direction must be up/down/left/right")
            }
            let amount = input["scroll_amount"]?.intValue ?? 3
            return .perform(.scroll(direction: direction, amount: amount, at: try point("coordinate"), modifiers: modifiers))
        case "type":
            return .perform(.type(text: try text()))
        case "key":
            let repeatCount = min(max(input["repeat"]?.intValue ?? 1, 1), 100)
            return .perform(.key(combo: try text(), repeat: repeatCount))
        case "hold_key":
            let seconds = min(input["duration"]?.doubleValue ?? 1, 300)
            return .perform(.holdKey(combo: try text(), seconds: seconds))
        case "wait":
            return .perform(.wait(seconds: min(input["duration"]?.doubleValue ?? 1, 300)))
        default:
            throw InvalidInput(tool: name, detail: "unknown computer tool")
        }
    }

    static func modifiers(_ text: String) -> [String] {
        text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    // MARK: Results

    public static func textResult(toolUseID: String, _ text: String, isError: Bool = false) -> JSONValue {
        var result: [String: JSONValue] = [
            "type": "tool_result",
            "tool_use_id": .string(toolUseID),
            "toolset_name": .string(toolsetName),
            "content": [["type": "text", "text": .string(text)]],
        ]
        if isError { result["is_error"] = true }
        return .object(result)
    }

    public static func imageResult(toolUseID: String, screenshot: Screenshot) -> JSONValue {
        [
            "type": "tool_result",
            "tool_use_id": .string(toolUseID),
            "toolset_name": .string(toolsetName),
            "content": [[
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": .string(screenshot.mediaType),
                    "data": .string(screenshot.imageData.base64EncodedString()),
                ],
            ]],
        ]
    }

    /// Answer for batch members after an earlier member in the same turn failed.
    public static func notExecuted(toolUseID: String) -> JSONValue {
        textResult(toolUseID: toolUseID, "Not executed: an earlier computer action in this turn failed.", isError: true)
    }
}

/// Screenshot size limits for Claude 5.x models: the guest must capture within these,
/// because the toolset takes no display size and the API does not downscale.
public enum ScreenshotLimits {
    public static let maxLongEdge = 2_576
    public static let maxPixels = 3_750_000

    /// Scale factor (≤ 1) to apply to a display of the given size before sending.
    public static func scale(width: Int, height: Int) -> Double {
        let longEdge = Double(maxLongEdge) / Double(max(width, height))
        let area = (Double(maxPixels) / Double(width * height)).squareRoot()
        return min(1, longEdge, area)
    }
}
