#if os(macOS)
import AppKit
import ApplicationServices
import BridgeProtocol

/// Reads the frontmost app's interactive elements from the accessibility tree, so the agent can find a control by
/// name instead of by pixels. Read-only: it never presses anything; clicks go through the normal input path.
///
/// Covers the app's focused window (with its sheets and dialogs), any floating panels and dialogs of its own, and
/// its menu bar with any open menu. Windows behind the focused one are left out: their controls are covered, and
/// listing them invites clicks on the wrong thing. Web content in Safari is part of the window, so links and form
/// fields show up too.
enum AccessibilityTree {
    /// Elements returned at most; the model asks again with a query to narrow down.
    static let limit = 150
    /// Nodes visited at most, so a huge web page or table can't stall the agent.
    static let nodeBudget = 4000
    static let maxDepth = 60

    /// Roles that are controls whatever their actions; anything else counts only if it can be pressed.
    private static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem",
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXLink", "AXSlider", "AXIncrementor",
        "AXDisclosureTriangle", "AXTab", "AXRow", "AXCell", "AXColorWell", "AXDateField",
    ]
    /// Containers whose children are never useful targets on their own.
    private static let skippedSubtrees: Set<String> = ["AXScrollBar", "AXValueIndicator"]

    static func elements(query: String?, scale: Double, display: CGRect) throws -> UIElementList {
        guard AXIsProcessTrusted() else {
            throw BridgeError(.permissionDenied, "Accessibility is not granted to ChatComputerAgent.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw BridgeError(.desktopUnavailable, "No app is in front.")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not hang the agent.
        AXUIElementSetMessagingTimeout(root, 1.0)

        var roots = frontWindows(of: root)
        if let menuBar: AXUIElement = attribute(root, kAXMenuBarAttribute) { roots.append(menuBar) }

        var walker = Walker(scale: scale, display: display, query: query.map(Self.fold).flatMap { $0.isEmpty ? nil : $0 })
        for element in roots { walker.visit(element, depth: 0) }
        return UIElementList(app: app.localizedName ?? "the frontmost app", elements: walker.found, truncated: walker.truncated)
    }

    /// The focused window (with its sheets, which are its children), and dialogs and panels floating above it.
    private static func frontWindows(of app: AXUIElement) -> [AXUIElement] {
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        var roots: [AXUIElement] = []
        if let focused: AXUIElement = attribute(app, kAXFocusedWindowAttribute) ?? windows.first { roots.append(focused) }
        for window in windows where !roots.contains(where: { CFEqual($0, window) }) {
            let subrole: String = attribute(window, kAXSubroleAttribute) ?? ""
            if ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow"].contains(subrole) { roots.append(window) }
        }
        return roots
    }

    // MARK: Text

    /// Characters returned at most; a long page is cut, not summarized.
    static let textLimit = 12_000
    static let textNodeBudget = 12_000

    /// The text of the window in front in reading order, the way a screen reader would read it, including what is
    /// scrolled out of view: a model can read a page or table exactly, without zooming into screenshots.
    static func text() throws -> UIText {
        guard AXIsProcessTrusted() else {
            throw BridgeError(.permissionDenied, "Accessibility is not granted to ChatComputerAgent.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw BridgeError(.desktopUnavailable, "No app is in front.")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.0)
        let windows = frontWindows(of: root)
        var reader = TextReader()
        for window in windows { reader.read(window, depth: 0) }
        reader.flush()
        // WebKit builds a page's accessibility tree on the first request: an empty first read gets a second one.
        if reader.lines.isEmpty {
            Thread.sleep(forTimeInterval: 0.4)
            reader = TextReader()
            for window in windows { reader.read(window, depth: 0) }
            reader.flush()
        }
        let title: String? = windows.first.flatMap { attribute($0, kAXTitleAttribute) }.flatMap { cleaned($0, limit: 120) }
        return UIText(app: app.localizedName ?? "the frontmost app", window: title, lines: reader.lines, truncated: reader.truncated)
    }

    private struct TextReader {
        var lines: [String] = []
        var truncated = false
        private var characters = 0
        private var visited = 0
        /// Adjacent pieces of one paragraph (web text arrives as runs: "Read ", "the docs", " today").
        private var paragraph: [String] = []
        private var seen: [CFHashCode: [AXUIElement]] = [:]

        /// Controls are listed by find_elements; their labels would only clutter the text.
        private static let skipped: Set<String> = [
            "AXScrollBar", "AXValueIndicator", "AXToolbar", "AXMenuBar", "AXMenu", "AXButton", "AXMenuButton",
            "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXImage",
            // A table lists the same cells under its columns as under its rows; rows read in order.
            "AXColumn",
        ]
        private static let paragraphBreaks: Set<String> = ["AXGroup", "AXList", "AXOutline", "AXTable", "AXScrollArea", "AXWebArea", "AXSplitGroup", "AXTabGroup", "AXSheet", "AXWindow"]

        mutating func read(_ element: AXUIElement, depth: Int) {
            guard depth <= AccessibilityTree.maxDepth, visited < AccessibilityTree.textNodeBudget, !truncated else { truncated = true; return }
            let hash = CFHash(element)
            if seen[hash, default: []].contains(where: { CFEqual($0, element) }) { return }
            seen[hash, default: []].append(element)
            visited += 1
            let role: String = AccessibilityTree.attribute(element, kAXRoleAttribute) ?? ""
            if Self.skipped.contains(role) { return }

            switch role {
            case "AXStaticText":
                if let text: String = AccessibilityTree.attribute(element, kAXValueAttribute), let clean = AccessibilityTree.cleaned(text, limit: 2000) {
                    paragraph.append(clean)
                }
                return
            case "AXLink":
                // Inline: its words belong to the sentence around it.
                if let text = AccessibilityTree.allText(in: element) { paragraph.append(text) }
                return
            case "AXHeading":
                flush()
                let title: String? = AccessibilityTree.attribute(element, kAXTitleAttribute)
                if let text = title.flatMap({ AccessibilityTree.cleaned($0, limit: 300) }) ?? AccessibilityTree.allText(in: element) {
                    emit("# " + text)
                }
                return
            case "AXRow":
                flush()
                let cells: [AXUIElement] = AccessibilityTree.attribute(element, kAXChildrenAttribute) ?? []
                let texts = cells.compactMap { AccessibilityTree.allText(in: $0) }
                if !texts.isEmpty { emit(texts.joined(separator: " | ")) }
                return
            case "AXTextArea", "AXTextField", "AXComboBox" where !AccessibilityTree.isEditable(element):
                // A read-only field is a label (a file name in a browser, a status line): plain text.
                if let text: String = AccessibilityTree.attribute(element, kAXValueAttribute), let clean = AccessibilityTree.cleaned(text, limit: 2000) {
                    paragraph.append(clean)
                }
                return
            case "AXTextArea", "AXTextField", "AXComboBox":
                flush()
                let label = AccessibilityTree.name(of: element, role: role)
                let value: String = AccessibilityTree.attribute(element, kAXValueAttribute) ?? ""
                let valueLines = value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if role == "AXTextArea", label.isEmpty {
                    valueLines.forEach { emit(String($0.prefix(2000))) }
                } else if !label.isEmpty || !valueLines.isEmpty {
                    emit((label.isEmpty ? "field" : label) + ": " + (valueLines.joined(separator: " ").isEmpty ? "(empty)" : valueLines.joined(separator: " ")))
                }
                return
            default:
                break
            }
            let breaks = Self.paragraphBreaks.contains(role)
            if breaks { flush() }
            for child: AXUIElement in AccessibilityTree.attribute(element, kAXChildrenAttribute) ?? [] {
                read(child, depth: depth + 1)
            }
            if breaks { flush() }
        }

        mutating func flush() {
            guard !paragraph.isEmpty else { return }
            let line = paragraph.joined(separator: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            paragraph = []
            if !line.isEmpty { emit(line) }
        }

        private mutating func emit(_ line: String) {
            guard lines.last != line else { return }
            guard characters + line.count <= AccessibilityTree.textLimit else { truncated = true; return }
            characters += line.count
            lines.append(line)
        }
    }

    /// Every piece of text inside an element, joined: a table cell, a link, a heading made of runs.
    fileprivate static func allText(in element: AXUIElement, depth: Int = 0) -> String? {
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        // An icon's description ("letter A icon") is not text anyone reads.
        if role == "AXImage" { return nil }
        if role == "AXStaticText" || role == "AXTextField" {
            return (attribute(element, kAXValueAttribute) as String?).flatMap { cleaned($0, limit: 500) }
        }
        guard depth < 6 else { return nil }
        let parts = (attribute(element, kAXChildrenAttribute) as [AXUIElement]? ?? []).compactMap { allText(in: $0, depth: depth + 1) }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        let title: String? = attribute(element, kAXTitleAttribute) ?? attribute(element, kAXDescriptionAttribute)
        return title.flatMap { cleaned($0, limit: 300) }
    }

    /// Whether the user can type into it; a field whose value can't be set is a label.
    fileprivate static func isEditable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// Case- and diacritic-insensitive, for matching what the model typed against what the app shows.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Walker {
        let scale: Double
        let display: CGRect
        let query: String?
        var found: [UIElement] = []
        var truncated = false
        var visited = 0
        /// Elements seen so far, by hash: a sheet is both a child of its window and listed as a window.
        var seen: [CFHashCode: [AXUIElement]] = [:]

        mutating func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= AccessibilityTree.maxDepth, visited < AccessibilityTree.nodeBudget else { truncated = true; return }
            let hash = CFHash(element)
            if seen[hash, default: []].contains(where: { CFEqual($0, element) }) { return }
            seen[hash, default: []].append(element)
            visited += 1
            let role: String = AccessibilityTree.attribute(element, kAXRoleAttribute) ?? ""
            if AccessibilityTree.skippedSubtrees.contains(role) { return }
            // Hidden or collapsed content has no frame on screen; its subtree is skipped with it.
            let frame = AccessibilityTree.frame(of: element)
            if let frame, role != "AXMenuBar", role != "AXMenu", !frame.intersects(display) { return }

            if let frame, AccessibilityTree.isControl(element, role: role), let entry = entry(element, role: role, frame: frame) {
                if found.count < AccessibilityTree.limit { found.append(entry) } else { truncated = true }
            }
            // A closed menu's items aren't on screen; an open one's are, as the menu bar item's AXMenu child.
            for child: AXUIElement in AccessibilityTree.attribute(element, kAXChildrenAttribute) ?? [] {
                visit(child, depth: depth + 1)
            }
        }

        private func entry(_ element: AXUIElement, role: String, frame: CGRect) -> UIElement? {
            let visible = frame.intersection(display)
            guard visible.width >= 2, visible.height >= 2 else { return nil }
            let subrole: String? = AccessibilityTree.attribute(element, kAXSubroleAttribute)
            let name = AccessibilityTree.name(of: element, role: role)
            let value = AccessibilityTree.value(of: element)
            let shortRole = AccessibilityTree.shortRole(role, subrole: subrole)
            // Unnamed controls are noise unless they take text: a text field is worth listing by its value.
            guard !name.isEmpty || role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" else { return nil }
            // A menu's alternate items (Close All under Close, shown only while Option is held) share their
            // twin's frame; only the visible one is clickable.
            if role == "AXMenuItem", found.contains(where: { $0.role == shortRole && $0.frame == rect(visible) }) { return nil }
            if let query {
                let haystack = [name, value ?? "", shortRole].map(AccessibilityTree.fold)
                guard haystack.contains(where: { $0.contains(query) }) else { return nil }
            }
            let enabled: Bool = AccessibilityTree.attribute(element, kAXEnabledAttribute) ?? true
            return UIElement(id: found.count + 1, role: shortRole, name: name, value: value, enabled: enabled, frame: rect(visible))
        }

        /// Display points to screenshot space.
        private func rect(_ frame: CGRect) -> ScreenRect {
            ScreenRect(x0: Int((frame.minX * scale).rounded()), y0: Int((frame.minY * scale).rounded()),
                       x1: Int((frame.maxX * scale).rounded()), y1: Int((frame.maxY * scale).rounded()))
        }
    }

    private static func isControl(_ element: AXUIElement, role: String) -> Bool {
        if controlRoles.contains(role) { return true }
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    /// "button", "textfield", "menuitem"; a search field keeps its subrole, which is what people call it.
    private static func shortRole(_ role: String, subrole: String?) -> String {
        if subrole == "AXSearchField" { return "searchfield" }
        if subrole == "AXSecureTextField" { return "securefield" }
        return (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role).lowercased()
    }

    /// The window's own buttons have only help text ("this button also has an action to zoom the window").
    private static let windowButtons = ["AXCloseButton": "close window", "AXMinimizeButton": "minimize window",
                                        "AXZoomButton": "zoom window", "AXFullScreenButton": "full screen"]

    fileprivate static func name(of element: AXUIElement, role: String) -> String {
        if let subrole: String = attribute(element, kAXSubroleAttribute), let name = windowButtons[subrole] { return name }
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", kAXPlaceholderValueAttribute, kAXHelpAttribute] {
            if let text: String = attribute(element, key), let clean = cleaned(text) { return clean }
        }
        // A row or cell (Finder's sidebar, a table) is named by the text inside it.
        if role == "AXRow" || role == "AXCell" || role == "AXLink" || role == "AXButton" {
            if let text = firstText(in: element, depth: 0) { return text }
        }
        // A labelled field: its title element is a separate static text.
        if let label: AXUIElement = attribute(element, kAXTitleUIElementAttribute),
           let text: String = attribute(label, kAXValueAttribute), let clean = cleaned(text) {
            return clean
        }
        return ""
    }

    private static func firstText(in element: AXUIElement, depth: Int) -> String? {
        guard depth < 4 else { return nil }
        for child: AXUIElement in attribute(element, kAXChildrenAttribute) ?? [] {
            let role: String = attribute(child, kAXRoleAttribute) ?? ""
            if role == "AXStaticText", let text: String = attribute(child, kAXValueAttribute), let clean = cleaned(text) { return clean }
            if let text = firstText(in: child, depth: depth + 1) { return text }
        }
        return nil
    }

    private static func value(of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success, let raw else { return nil }
        if let text = raw as? String { return cleaned(text, limit: 80) }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    fileprivate static func cleaned(_ text: String, limit: Int = 60) -> String? {
        let single = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !single.isEmpty else { return nil }
        return single.count > limit ? String(single.prefix(limit - 1)) + "…" : single
    }

    /// Global display points, top-left origin: the same space as CGEvent locations.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Strings, numbers and booleans bridge safely with `as?`; CF types don't (any CFTypeRef casts to them),
    /// so those go through the typed helpers below, which check the type ID.
    fileprivate static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        if T.self == AXValue.self {
            return CFGetTypeID(value) == AXValueGetTypeID() ? (value as! T) : nil
        }
        if T.self == [AXUIElement].self {
            guard CFGetTypeID(value) == CFArrayGetTypeID(), let array = value as? [AnyObject] else { return nil }
            return array.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement } as? T
        }
        return value as? T
    }
}
#endif
