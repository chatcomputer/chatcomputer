import Foundation

/// Fills in and confirms a macOS save or export dialog with real key presses, the same way every time.
///
/// The dialog is an out-of-process panel, and it has a quirk (measured on macOS 27, see docs/ROADMAP.md §5.1):
/// after any Command or Control shortcut, including the Cmd+S that opened it, it drops plain typing until the
/// next click inside it. Shift and Option combinations don't do this. So every text field is clicked first, and
/// its text is selected with Down then Shift+Up rather than Cmd+A, and each field is read back from the screen.
public enum SaveDialog {
    /// Sends one input to the guest; returns false when the guest refused it (no lease, driver error).
    public typealias Send = @Sendable (ComputerAction) async -> Bool
    /// A fresh screenshot of the guest, already searched for the given text: where it is, if visible.
    public typealias Locate = @Sendable (String) async -> ScreenPoint?

    public enum Outcome: Equatable, Sendable {
        /// Save was pressed with the name and folder filled in.
        case pressedSave
        /// No save dialog appeared, so nothing was typed (typing would have gone into the document).
        case noDialog
        /// The guest refused an input (no lease, driver error).
        case refused
    }

    /// Where the name field sits relative to the centre of its "Save As:" label.
    static let nameFieldOffset = 150

    /// Fills in the dialog and saves. With `locate` (screen reading) it waits for each panel, clicks its field
    /// and checks what was typed; without it, it falls back to fixed pauses.
    public static func run(name: String, folder: String, openDialog: Bool, send: Send, locate: Locate?,
                           sleep: @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) async -> Outcome {
        func key(_ combo: String) async -> Bool { await send(.key(combo: combo, repeat: 1)) }
        func type(_ text: String) async -> Bool { await send(.type(text: text)) }
        func click(_ point: ScreenPoint) async -> Bool { await send(.click(button: .left, count: 1, at: point, modifiers: [])) }
        /// Polls the screen for any of `texts`, up to `seconds`.
        func waitFor(_ texts: [String], seconds: Double) async -> ScreenPoint? {
            guard let locate else { await sleep(min(seconds, 2.0)); return nil }
            for _ in 0..<max(1, Int(seconds * 2)) {
                for text in texts { if let point = await locate(text) { return point } }
                await sleep(0.5)
            }
            return nil
        }
        /// Clicks the field, replaces its text, and checks `expected` is showing; one retry.
        func fill(_ field: ScreenPoint?, with text: String, expected: String) async -> Bool {
            for attempt in 0..<2 {
                if let field {
                    guard await click(field) else { return false }
                    await sleep(0.5)
                }
                guard await key("down"), await key("shift+up"), await type(text) else { return false }
                await sleep(0.8)
                guard let locate, field != nil, attempt == 0, !expected.isEmpty, await locate(expected) == nil else { return true }
            }
            return true
        }

        if openDialog {
            guard await key("cmd+s") else { return .refused }
        }
        let label = await waitFor(["Save As", "Export As"], seconds: 6)
        if locate != nil, label == nil { return .noDialog }

        // The name: the field sits right of its label.
        let nameField = label.map { ScreenPoint(x: $0.x + nameFieldOffset, y: $0.y) }
        guard await fill(nameField, with: name, expected: name) else { return .refused }

        // The folder, through Go to Folder. Its field takes typing only after a click, like the name field.
        guard await key("cmd+shift+g") else { return .refused }
        let pathField = await waitFor(["Go to Folder"], seconds: 6)
        guard await fill(pathField, with: folder, expected: (folder as NSString).lastPathComponent) else { return .refused }
        guard await key("return") else { return .refused }
        await sleep(1.0)

        guard await key("return") else { return .refused }
        await sleep(2.0)
        return .pressedSave
    }

    /// A file name the dialog can take as typed: no folders, nothing empty.
    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains("/") && !trimmed.contains(":") && trimmed != "." && trimmed != ".."
    }

    /// A warning when the app saved under a different name than asked: TextEdit adds ".rtf" to "notes.txt" when
    /// the document is rich text, and a check for the plain-text file then fails.
    public static func extensionWarning(requested name: String, saved file: URL) -> String? {
        guard file.lastPathComponent != name, !(name as NSString).pathExtension.isEmpty else { return nil }
        return " Note: the app saved it as \"\(file.lastPathComponent)\", not \"\(name)\", because the document is in another " +
            "format. For plain text in TextEdit, choose Format › Make Plain Text (Cmd+Shift+T), then call save_file again."
    }

    /// Files in `folder` that the save produced: `name` itself, or `name` plus an extension the app added
    /// (TextEdit appends .txt or .rtf when the name has none).
    public static func savedFiles(named name: String, in folder: URL) -> [URL] {
        let exact = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: exact.path) { return [exact] }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return entries.filter { ($0 as NSString).deletingPathExtension == name }.map { folder.appendingPathComponent($0) }
    }
}
