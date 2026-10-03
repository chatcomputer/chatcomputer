import Foundation
import ModelProxy

/// Turns `chatcomputer` command-line arguments into a control request.
public enum ControlCLI {
    public enum Invocation: Equatable {
        case help
        case mcp
        /// `screenshotPath` is where to save a screenshot, if the user chose one.
        case request(command: String, arguments: [String: JSONValue], screenshotPath: String?)
    }

    public static func parse(_ arguments: [String]) throws -> Invocation {
        guard let first = arguments.first else { return .help }
        var rest = Array(arguments.dropFirst())

        func flag(_ name: String) -> Bool {
            guard let index = rest.firstIndex(of: name) else { return false }
            rest.remove(at: index)
            return true
        }
        func option(_ name: String) throws -> String? {
            guard let index = rest.firstIndex(of: name) else { return nil }
            guard index + 1 < rest.count else { throw ControlError.usage("\(name) needs a value") }
            let value = rest[index + 1]
            rest.removeSubrange(index...(index + 1))
            return value
        }
        func integers(_ names: [String], usage: String) throws -> [String: JSONValue] {
            guard rest.count >= names.count else { throw ControlError.usage("Usage: chatcomputer \(usage)") }
            var result: [String: JSONValue] = [:]
            for name in names {
                guard let value = Int(rest.removeFirst()) else { throw ControlError.usage("Usage: chatcomputer \(usage) (whole numbers)") }
                result[name] = .number(Double(value))
            }
            return result
        }
        func done(_ command: String, _ arguments: [String: JSONValue] = [:], screenshotPath: String? = nil) throws -> Invocation {
            guard rest.isEmpty else { throw ControlError.usage("Unexpected argument `\(rest[0])` for \(command). Run `chatcomputer help`.") }
            return .request(command: command, arguments: arguments, screenshotPath: screenshotPath)
        }

        switch first {
        case "help", "--help", "-h": return .help
        case "mcp": return .mcp
        case "status", "outbox", "release": return try done(first)
        case "screenshot":
            let path = try option("--out")
            if rest.isEmpty { return try done("screenshot", screenshotPath: path) }
            let region = try integers(["x0", "y0", "x1", "y1"], usage: "screenshot [X0 Y0 X1 Y1] [--out FILE]")
            let values: [JSONValue] = ["x0", "y0", "x1", "y1"].compactMap { region[$0] }
            return try done("screenshot", ["region": .array(values)], screenshotPath: path)
        case "click":
            var arguments: [String: JSONValue] = [:]
            if flag("--right") { arguments["button"] = "right" }
            if flag("--middle") { arguments["button"] = "middle" }
            if flag("--double") { arguments["count"] = 2 }
            if let mods = try option("--mods") {
                arguments["modifiers"] = .array(mods.split(separator: ",").map { .string(String($0)) })
            }
            arguments.merge(try integers(["x", "y"], usage: "click X Y [--right|--middle] [--double] [--mods cmd,shift]")) { $1 }
            return try done("click", arguments)
        case "move":
            return try done("move", try integers(["x", "y"], usage: "move X Y"))
        case "drag":
            return try done("drag", try integers(["x1", "y1", "x2", "y2"], usage: "drag X1 Y1 X2 Y2"))
        case "scroll":
            var arguments = try integers(["x", "y"], usage: "scroll X Y up|down|left|right [AMOUNT]")
            guard !rest.isEmpty else { throw ControlError.usage("Usage: chatcomputer scroll X Y up|down|left|right [AMOUNT]") }
            arguments["direction"] = .string(rest.removeFirst())
            if !rest.isEmpty { arguments.merge(try integers(["amount"], usage: "scroll X Y DIRECTION [AMOUNT]")) { $1 } }
            return try done("scroll", arguments)
        case "type":
            guard !rest.isEmpty else { throw ControlError.usage("Usage: chatcomputer type TEXT...") }
            let text = rest.joined(separator: " ")
            rest = []
            return try done("type", ["text": .string(text)])
        case "key":
            var arguments: [String: JSONValue] = [:]
            if let count = try option("--repeat") {
                guard let value = Int(count) else { throw ControlError.usage("--repeat needs a whole number") }
                arguments["repeat"] = .number(Double(value))
            }
            guard rest.count == 1 else { throw ControlError.usage("Usage: chatcomputer key COMBO [--repeat N]") }
            arguments["combo"] = .string(rest.removeFirst())
            return try done("key", arguments)
        case "wait":
            guard rest.count == 1, let seconds = Double(rest.removeFirst()) else { throw ControlError.usage("Usage: chatcomputer wait SECONDS") }
            return try done("wait", ["seconds": .number(seconds)])
        case "put":
            guard rest.count == 1 else { throw ControlError.usage("Usage: chatcomputer put FILE") }
            let path = URL(fileURLWithPath: rest.removeFirst()).standardizedFileURL.path
            return try done("put_file", ["path": .string(path)])
        case "share":
            guard !rest.isEmpty else { throw ControlError.usage("Usage: chatcomputer share list | add FOLDER [--writable] | remove NAME") }
            switch rest.removeFirst() {
            case "list": return try done("share_list")
            case "add":
                let writable = flag("--writable")
                guard rest.count == 1 else { throw ControlError.usage("Usage: chatcomputer share add FOLDER [--writable]") }
                let path = URL(fileURLWithPath: rest.removeFirst()).standardizedFileURL.path
                return try done("share_add", ["path": .string(path), "writable": .bool(writable)])
            case "remove":
                guard !rest.isEmpty else { throw ControlError.usage("Usage: chatcomputer share remove NAME") }
                let name = rest.joined(separator: " ")
                rest = []
                return try done("share_remove", ["name": .string(name)])
            case let other:
                throw ControlError.usage("Unknown share command `\(other)`. Use list, add or remove.")
            }
        case "snapshot":
            guard !rest.isEmpty else { throw ControlError.usage("Usage: chatcomputer snapshot list | take [NAME] | restore NAME|ID [--no-save]") }
            switch rest.removeFirst() {
            case "list": return try done("snapshot_list")
            case "take":
                let name = rest.joined(separator: " ")
                rest = []
                return try done("snapshot_take", name.isEmpty ? [:] : ["name": .string(name)])
            case "restore":
                let noSave = flag("--no-save")
                guard !rest.isEmpty else { throw ControlError.usage("Usage: chatcomputer snapshot restore NAME|ID [--no-save]") }
                let name = rest.joined(separator: " ")
                rest = []
                return try done("snapshot_restore", ["snapshot": .string(name), "save_current": .bool(!noSave)])
            case "delete":
                guard !rest.isEmpty else { throw ControlError.usage("Usage: chatcomputer snapshot delete NAME|ID") }
                let name = rest.joined(separator: " ")
                rest = []
                return try done("snapshot_delete", ["snapshot": .string(name)])
            case let other:
                throw ControlError.usage("Unknown snapshot command `\(other)`. Use list, take, restore or delete.")
            }
        default:
            throw ControlError.unknownCommand(first)
        }
    }

    /// Who is running the command, from the environment coding agents set for their shells.
    public static func clientName(environment: [String: String]) -> String {
        if let name = environment["CHATCOMPUTER_CLIENT"], !name.isEmpty { return name }
        if environment["CLAUDECODE"] == "1" { return "Claude Code" }
        if environment.keys.contains(where: { $0.hasPrefix("CODEX_") }) { return "Codex" }
        if environment.keys.contains(where: { $0.hasPrefix("CURSOR_") }) { return "Cursor" }
        if environment["GEMINI_CLI"] == "1" { return "Gemini CLI" }
        return "Command line"
    }

    /// Which control commands (MCP tool names) each command-line command reaches. Tests check that together
    /// they cover `ControlTool.all` exactly, so the two entry points can't drift apart.
    public static let toolsByCommand: [String: [String]] = [
        "status": ["status"], "screenshot": ["screenshot"], "click": ["click"], "move": ["move"], "drag": ["drag"],
        "scroll": ["scroll"], "type": ["type"], "key": ["key"], "wait": ["wait"], "release": ["release"],
        "snapshot": ["snapshot_list", "snapshot_take", "snapshot_restore", "snapshot_delete"],
        "put": ["put_file"], "outbox": ["outbox"],
        "share": ["share_list", "share_add", "share_remove"],
    ]

    /// Names that switch the app's executable into command-line mode.
    public static let commands: Set<String> = Set(toolsByCommand.keys).union(["help", "--help", "-h", "mcp"])
}
