import BridgeProtocol
import Foundation

/// Host tools that work on the guest's accessibility tree: list the controls of the frontmost app as text, and
/// click one by its number or name. They spare a model the guesswork of pixel coordinates on small or dense
/// controls, which is where weaker models spend most of their turns. Offered only when the guest agent reports
/// `supportsAccessibilityTree`.
public enum ElementTools {
    public static let findElements = "find_elements"
    public static let clickElement = "click_element"
    public static let names: Set<String> = [findElements, clickElement]

    public static let definitions: [JSONValue] = [
        [
            "name": .string(findElements),
            "description": """
                List the controls of the app in front (buttons, fields, menu items, links, rows, its open menus and \
                dialogs) by name, with their position in screenshot coordinates. Faster and more precise than reading \
                small text off a screenshot. Pass a query to keep only controls whose name, value or role contains it.
                """,
            "input_schema": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "query": ["type": "string", "description": "Optional text to look for, e.g. \"Save\" or \"search\"."],
                ],
            ],
        ],
        [
            "name": .string(clickElement),
            "description": """
                Click a control of the app in front: by its number from the last find_elements list, or by its name \
                (optionally with its role, e.g. "button"). A name that matches more than one control returns the \
                candidates instead of clicking. Use it for named controls; use the computer tool for anything else.
                """,
            "input_schema": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "id": ["type": "integer", "description": "The number shown by find_elements."],
                    "name": ["type": "string", "description": "The control's name, as shown on screen."],
                    "role": ["type": "string", "description": "Optional: button, textfield, menuitem, link, checkbox, row, …"],
                ],
            ],
        ],
    ]

    public struct Click: Equatable, Sendable {
        public var id: Int?
        public var name: String?
        public var role: String?
    }

    public static func parseFind(_ input: JSONValue) -> String? {
        input["query"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    public static func parseClick(_ input: JSONValue) -> Click? {
        let id = input["id"]?.intValue
        let name = input["name"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        guard id != nil || name != nil else { return nil }
        return Click(id: id, name: name, role: input["role"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// One line per control: `[3] button "Save" at (640, 412)`, plus value and disabled state when they matter.
    public static func describe(_ list: UIElementList, query: String?) -> String {
        guard !list.elements.isEmpty else {
            let filter = query.map { " matching \"\($0)\"" } ?? ""
            return "\(list.app): no controls\(filter) found. Take a screenshot; the control may be off screen, or drawn without accessibility."
        }
        var lines = ["\(list.app), \(list.elements.count) controls\(query.map { " matching \"\($0)\"" } ?? ""). Click one with click_element(id)."]
        for element in list.elements {
            var line = "[\(element.id)] \(element.role)" + (element.name.isEmpty ? "" : " \"\(element.name)\"")
            if let value = element.value, !value.isEmpty, value != element.name { line += " value \"\(value)\"" }
            line += " at (\(element.center.x), \(element.center.y))"
            if !element.enabled { line += " disabled" }
            lines.append(line)
        }
        if list.truncated { lines.append("More controls exist; pass a query to narrow the list.") }
        return lines.joined(separator: "\n")
    }

    public enum Match: Equatable, Sendable {
        case found(UIElement)
        case none
        case ambiguous([UIElement])
    }

    /// Picks the control a name refers to: an exact name beats a partial one, and a role narrows the field.
    /// Never guesses between equals.
    public static func match(_ name: String, role: String?, in elements: [UIElement]) -> Match {
        let wanted = fold(name)
        let roleWanted = role.map(fold)
        let candidates = elements.filter { element in
            guard let roleWanted else { return true }
            return fold(element.role) == roleWanted || fold(element.role).contains(roleWanted)
        }
        let exact = candidates.filter { fold($0.name) == wanted }
        let partial = exact.isEmpty ? candidates.filter { fold($0.name).contains(wanted) } : exact
        // Prefer enabled controls when the name alone is ambiguous: a greyed-out twin is rarely meant.
        let pool = partial.filter(\.enabled).isEmpty ? partial : partial.filter(\.enabled)
        switch pool.count {
        case 0: return .none
        case 1: return .found(pool[0])
        default: return .ambiguous(pool)
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
