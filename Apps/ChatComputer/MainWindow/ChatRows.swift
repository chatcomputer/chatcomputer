import AppKit
import ListViewKit
import MarkdownView

/// Layout shared by the rows and their height closures, which must agree exactly.
@MainActor
enum ChatLayout {
    static let side: CGFloat = 14
    static let gap: CGFloat = 5          // above and below every row
    static let cardPadding: CGFloat = 10
    static let cardHeader: CGFloat = 22  // "Result" / "Waiting for your reply"
    static let fileButton: CGFloat = 26
    static let bubblePadding: CGFloat = 9
    static let bubbleMaxShare: CGFloat = 0.85
    static let iconColumn: CGFloat = 18
    static let copyColumn: CGFloat = 24

    static var theme: MarkdownTheme { .default }
}

/// Parsed Markdown per message, so measuring and showing a row parse it once. Keyed by text: a message's text only
/// changes when it is a different message.
@MainActor
enum MarkdownCache {
    private static var contents: [String: MarkdownContent] = [:]
    private static var heights: [String: CGFloat] = [:]
    private static let sizer = MarkdownTextView()

    static func content(for text: String) -> MarkdownContent {
        if let cached = contents[text] { return cached }
        let content = MarkdownContent(markdown: text, theme: ChatLayout.theme)
        if contents.count > 2000 { contents.removeAll(); heights.removeAll() }
        contents[text] = content
        return content
    }

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let key = "\(Int(width))|\(text)"
        if let cached = heights[key] { return cached }
        sizer.setContentImmediately(content(for: text), theme: ChatLayout.theme)
        let height = ceil(sizer.boundingSize(for: width).height)
        heights[key] = height
        return height
    }
}

// MARK: Agent messages (Markdown)

/// What the agent says: along the way as plain Markdown, and the task's result or a question as a card.
final class MarkdownRow: ListRowView {
    private let card = NSView()
    private let header = NSTextField(labelWithString: "")
    private let body = MarkdownTextView()
    private let copyButton = NSButton()
    private var files = FileButtons()
    private var item: ChatItem?
    private var tracking: NSTrackingArea?
    var onExport: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        body.linkHandler = { payload, _, _ in
            if case .url(let url) = payload { NSWorkspace.shared.open(url) }
        }
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.isBordered = false
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = "Copy this message as Markdown"
        copyButton.target = self
        copyButton.action = #selector(copy(_:))
        copyButton.alphaValue = 0
        for view in [card, header, body, files, copyButton] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    static func height(for item: ChatItem, width: CGFloat) -> CGFloat {
        let inner = textWidth(for: item, rowWidth: width)
        var height = MarkdownCache.height(for: item.text, width: inner)
        if item.emphasis != nil { height += 2 * ChatLayout.cardPadding + ChatLayout.cardHeader }
        height += CGFloat(item.files.count) * ChatLayout.fileButton
        return height + 2 * ChatLayout.gap
    }

    private static func textWidth(for item: ChatItem, rowWidth: CGFloat) -> CGFloat {
        // A card's copy button sits in its header row; a plain message keeps a column free for it.
        let inset = ChatLayout.side * 2 + (item.emphasis != nil ? 2 * ChatLayout.cardPadding : ChatLayout.copyColumn)
        return max(40, rowWidth - inset)
    }

    func show(_ item: ChatItem) {
        self.item = item
        body.setContentImmediately(MarkdownCache.content(for: item.text), theme: ChatLayout.theme)
        switch item.emphasis {
        case .result:
            header.stringValue = "✓  Result"
            header.textColor = .systemGreen
        case .question:
            header.stringValue = "?  Waiting for your reply"
            header.textColor = .systemOrange
        case nil:
            header.stringValue = ""
        }
        header.isHidden = item.emphasis == nil
        card.isHidden = item.emphasis == nil
        files.show(item.files) { [weak self] in self?.onExport?($0) }
        needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        body.textLabelView.clearSelection()
        copyButton.alphaValue = 0
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        let width = bounds.width
        let textWidth = Self.textWidth(for: item, rowWidth: width)
        let textHeight = MarkdownCache.height(for: item.text, width: textWidth)
        var y = ChatLayout.gap
        if item.emphasis != nil {
            let cardHeight = 2 * ChatLayout.cardPadding + ChatLayout.cardHeader + textHeight
            card.frame = NSRect(x: ChatLayout.side, y: y, width: width - 2 * ChatLayout.side, height: cardHeight)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                card.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
                card.layer?.borderColor = NSColor.separatorColor.cgColor
            }
            card.layer?.borderWidth = 1
            y += ChatLayout.cardPadding
            header.frame = NSRect(x: ChatLayout.side + ChatLayout.cardPadding, y: y, width: textWidth, height: ChatLayout.cardHeader - 4)
            y += ChatLayout.cardHeader
            body.frame = NSRect(x: ChatLayout.side + ChatLayout.cardPadding, y: y, width: textWidth, height: textHeight)
            y += textHeight + ChatLayout.cardPadding
        } else {
            body.frame = NSRect(x: ChatLayout.side, y: y, width: textWidth, height: textHeight)
            y += textHeight
        }
        files.frame = NSRect(x: ChatLayout.side, y: y, width: width - 2 * ChatLayout.side,
                             height: CGFloat(item.files.count) * ChatLayout.fileButton)
        copyButton.frame = NSRect(x: width - ChatLayout.side - 20, y: ChatLayout.gap + (item.emphasis != nil ? 6 : -2), width: 18, height: 18)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { copyButton.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { copyButton.animator().alphaValue = 0 }

    @objc private func copy(_ sender: Any?) {
        guard let item else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
    }
}

// MARK: Everything else (plain text)

/// Your messages (a bubble on the right), the agent's steps (small monospaced) and Chat Computer's own notes
/// (small, with an icon), with any delivered files below.
final class TextRow: ListRowView {
    private let bubble = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var files = FileButtons()
    private var item: ChatItem?
    var onExport: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 10
        label.isSelectable = true
        label.allowsEditingTextAttributes = false
        label.drawsBackground = false
        label.isBordered = false
        icon.contentTintColor = .secondaryLabelColor
        for view in [bubble, icon, label, files] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private static func text(for item: ChatItem) -> NSAttributedString {
        let font: NSFont
        let color: NSColor
        switch item.role {
        case .user:
            font = .systemFont(ofSize: NSFont.systemFontSize)
            color = .labelColor
        case .action:
            font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            color = .secondaryLabelColor
        default:
            font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
            color = .secondaryLabelColor
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        // Notes may carry inline Markdown (**bold**, links); render that, keep everything else literal.
        var string = NSMutableAttributedString(string: item.text)
        if item.role == .system || item.role == .status,
           let parsed = try? NSAttributedString(markdown: item.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            string = NSMutableAttributedString(attributedString: parsed)
        }
        let whole = NSRange(location: 0, length: string.length)
        string.addAttribute(.foregroundColor, value: color, range: whole)
        string.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        string.enumerateAttribute(.font, in: whole) { value, range, _ in
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let base = traits.contains(.bold) ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
            string.addAttribute(.font, value: base, range: range)
        }
        return string
    }

    private static func layout(for item: ChatItem, width: CGFloat) -> (textWidth: CGFloat, textX: CGFloat, padding: CGFloat) {
        switch item.role {
        case .user:
            let maxText = (width - 2 * ChatLayout.side) * ChatLayout.bubbleMaxShare - 2 * ChatLayout.bubblePadding
            let natural = ceil(text(for: item).boundingRect(with: NSSize(width: maxText, height: .greatestFiniteMagnitude),
                                                             options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
            let textWidth = min(maxText, max(natural, 8))
            return (textWidth, width - ChatLayout.side - ChatLayout.bubblePadding - textWidth, ChatLayout.bubblePadding)
        case .system, .status:
            return (width - 2 * ChatLayout.side - ChatLayout.iconColumn, ChatLayout.side + ChatLayout.iconColumn, 0)
        default:
            return (width - 2 * ChatLayout.side, ChatLayout.side, 0)
        }
    }

    static func height(for item: ChatItem, width: CGFloat) -> CGFloat {
        let geometry = layout(for: item, width: width)
        let text = ceil(text(for: item).boundingRect(with: NSSize(width: geometry.textWidth, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        return text + 2 * geometry.padding + CGFloat(item.files.count) * ChatLayout.fileButton + 2 * ChatLayout.gap
    }

    func show(_ item: ChatItem) {
        self.item = item
        label.attributedStringValue = Self.text(for: item)
        bubble.isHidden = item.role != .user
        icon.isHidden = !(item.role == .system || item.role == .status)
        if item.role == .status {
            icon.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 5, weight: .regular))
        } else if item.role == .system {
            icon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        }
        files.show(item.files) { [weak self] in self?.onExport?($0) }
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        let width = bounds.width
        let geometry = Self.layout(for: item, width: width)
        let textHeight = ceil(label.attributedStringValue.boundingRect(
            with: NSSize(width: geometry.textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let y = ChatLayout.gap + geometry.padding
        label.frame = NSRect(x: geometry.textX, y: y, width: geometry.textWidth + 4, height: textHeight)
        if item.role == .user {
            bubble.frame = NSRect(x: geometry.textX - ChatLayout.bubblePadding, y: ChatLayout.gap,
                                  width: geometry.textWidth + 2 * ChatLayout.bubblePadding + 4, height: textHeight + 2 * ChatLayout.bubblePadding)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                bubble.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            }
        }
        icon.frame = NSRect(x: ChatLayout.side, y: y + 1, width: 14, height: 14)
        files.frame = NSRect(x: ChatLayout.side, y: y + textHeight + geometry.padding,
                             width: width - 2 * ChatLayout.side, height: CGFloat(item.files.count) * ChatLayout.fileButton)
    }
}

/// One button per delivered file; clicking saves it to this Mac.
final class FileButtons: NSView {
    private var action: ((URL) -> Void)?
    private var urls: [URL] = []

    override var isFlipped: Bool { true }

    func show(_ files: [URL], action: @escaping (URL) -> Void) {
        self.action = action
        urls = files
        subviews.forEach { $0.removeFromSuperview() }
        for (index, url) in files.enumerated() {
            let button = NSButton(title: url.lastPathComponent, image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)!,
                                  target: self, action: #selector(save(_:)))
            button.tag = index
            button.bezelStyle = .push
            button.controlSize = .small
            button.imagePosition = .imageLeading
            button.toolTip = "Save \(url.lastPathComponent) to this Mac"
            addSubview(button)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (index, button) in subviews.compactMap({ $0 as? NSButton }).enumerated() {
            button.sizeToFit()
            button.frame.origin = NSPoint(x: 0, y: CGFloat(index) * ChatLayout.fileButton + 2)
            button.frame.size.width = min(button.frame.width, bounds.width)
        }
    }

    @objc private func save(_ sender: NSButton) {
        guard urls.indices.contains(sender.tag) else { return }
        action?(urls[sender.tag])
    }
}
