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

        let windows: [AXUIElement] = attribute(root, kAXWindowsAttribute) ?? []
        var roots: [AXUIElement] = []
        if let focused: AXUIElement = attribute(root, kAXFocusedWindowAttribute) ?? windows.first { roots.append(focused) }
        // Dialogs and panels float above the focused window, so they are on screen too.
        for window in windows where !roots.contains(where: { CFEqual($0, window) }) {
            let subrole: String = attribute(window, kAXSubroleAttribute) ?? ""
            if ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow"].contains(subrole) { roots.append(window) }
        }
        if let menuBar: AXUIElement = attribute(root, kAXMenuBarAttribute) { roots.append(menuBar) }

        var walker = Walker(scale: scale, display: display, query: query.map(Self.fold).flatMap { $0.isEmpty ? nil : $0 })
        for element in roots { walker.visit(element, depth: 0) }
        return UIElementList(app: app.localizedName ?? "the frontmost app", elements: walker.found, truncated: walker.truncated)
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

    private static func name(of element: AXUIElement, role: String) -> String {
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

    private static func cleaned(_ text: String, limit: Int = 60) -> String? {
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
    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
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
