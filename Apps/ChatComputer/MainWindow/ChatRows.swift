import AppKit
import ListViewKit
import MarkdownView

/// Layout shared by the rows and their height closures, which must agree exactly.
@MainActor
enum ChatLayout {
    static let side: CGFloat = 14
    static let gap: CGFloat = 5          // above and below every row
    static let cardPadding: CGFloat = 10
    static let cardHeader: CGFloat = 22  // "Waiting for your reply"
    static let fileButton: CGFloat = 26
    static let bubblePadding: CGFloat = 9
    static let bubbleMaxShare: CGFloat = 0.85
    static let iconColumn: CGFloat = 18
    static let copyColumn: CGFloat = 24

    static var theme: MarkdownTheme { .default }

    /// The agent's folded steps: smaller, quieter, and tight, so a long task reads as a log rather than a letter.
    static let stepsTheme: MarkdownTheme = {
        var theme = MarkdownTheme.default
        let size = NSFont.smallSystemFontSize + 1
        theme.fonts.body = .systemFont(ofSize: size)
        theme.fonts.bold = .systemFont(ofSize: size, weight: .semibold)
        theme.fonts.italic = NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
        theme.fonts.title = .systemFont(ofSize: size, weight: .semibold)
        theme.fonts.largeTitle = .systemFont(ofSize: size, weight: .semibold)
        theme.fonts.codeInline = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
        theme.fonts.code = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
        theme.colors.body = .secondaryLabelColor
        theme.colors.code = .secondaryLabelColor
        theme.spacings.paragraph = 6
        theme.spacings.general = 4
        theme.spacings.list = 4
        theme.spacings.final = 0
        return theme
    }()
}

/// How a piece of Markdown is set: as a message, or among the agent's folded steps.
enum MarkdownStyle: String {
    case message, steps

    @MainActor var theme: MarkdownTheme { self == .steps ? ChatLayout.stepsTheme : ChatLayout.theme }
}

/// Parsed Markdown per message, so measuring and showing a row parse it once. Keyed by style and text: a message's
/// text only changes when it is a different message.
@MainActor
enum MarkdownCache {
    private static var contents: [String: MarkdownContent] = [:]
    private static var heights: [String: CGFloat] = [:]
    private static let sizer = MarkdownTextView()

    static func content(for text: String, style: MarkdownStyle = .message) -> MarkdownContent {
        let key = "\(style.rawValue)|\(text)"
        if let cached = contents[key] { return cached }
        let content = MarkdownContent(markdown: delimitingURLs(in: text), theme: style.theme)
        if contents.count > 2000 { contents.removeAll(); heights.removeAll() }
        contents[key] = content
        return content
    }

    static func height(for text: String, width: CGFloat, style: MarkdownStyle = .message) -> CGFloat {
        let key = "\(style.rawValue)|\(Int(width))|\(text)"
        if let cached = heights[key] { return cached }
        sizer.setContentImmediately(content(for: text, style: style), theme: style.theme)
        let height = ceil(sizer.boundingSize(for: width).height)
        heights[key] = height
        return height
    }

    private static let bareURL = try! NSRegularExpression(
        pattern: #"(?<![<(\[\w/])https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%\p{L}\p{N}]+"#)

    /// GitHub's autolinks run to the next space, so a URL followed by Chinese text ("…google.com），页面…") takes the
    /// sentence with it. Marking each bare URL as `<url>`, ended at the first character that is neither a URL
    /// character nor a letter or digit (full-width punctuation ends it; "wiki/苹果公司" stays whole), stops it there.
    /// Code is left alone. Only what is shown changes; copying gives the agent's text.
    static func delimitingURLs(in text: String) -> String {
        guard text.contains("://") else { return text }
        var inFence = false
        return text.components(separatedBy: "\n").map { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); return line }
            if inFence { return line }
            // Outside inline code spans: the even pieces between backticks.
            return line.components(separatedBy: "`").enumerated().map { index, piece in
                index.isMultiple(of: 2) ? delimit(piece) : piece
            }.joined(separator: "`")
        }.joined(separator: "\n")
    }

    private static func delimit(_ text: String) -> String {
        let source = text as NSString
        var result = ""
        var last = 0
        for match in bareURL.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            var url = source.substring(with: match.range)
            // Sentence punctuation after a URL, and a closing bracket it didn't open, aren't part of it.
            while let end = url.last, ".,;:!?'\"".contains(end)
                    || (end == ")" && url.count(where: { $0 == ")" }) > url.count(where: { $0 == "(" }))
                    || (end == "]" && url.count(where: { $0 == "]" }) > url.count(where: { $0 == "[" })) {
                url.removeLast()
            }
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            result += "<\(url)>"
            last = match.range.location + (url as NSString).length
        }
        return result + source.substring(from: last)
    }
}

// MARK: Agent messages (Markdown)

/// What the agent says: its answer as plain Markdown, and a question that waits for you as a card.
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

    /// A question waits for you, so it stands out as a card. A result needs no frame: the folded steps above it
    /// already set it apart.
    private static func isCard(_ item: ChatItem) -> Bool { item.emphasis == .question }

    static func height(for item: ChatItem, width: CGFloat) -> CGFloat {
        let inner = textWidth(for: item, rowWidth: width)
        var height = MarkdownCache.height(for: item.text, width: inner)
        if isCard(item) { height += 2 * ChatLayout.cardPadding + ChatLayout.cardHeader }
        height += CGFloat(item.files.count) * ChatLayout.fileButton
        return height + 2 * ChatLayout.gap
    }

    private static func textWidth(for item: ChatItem, rowWidth: CGFloat) -> CGFloat {
        // A card's copy button sits in its header row; a plain message keeps a column free for it.
        let inset = ChatLayout.side * 2 + (isCard(item) ? 2 * ChatLayout.cardPadding : ChatLayout.copyColumn)
        return max(40, rowWidth - inset)
    }

    func show(_ item: ChatItem) {
        self.item = item
        body.setContentImmediately(MarkdownCache.content(for: item.text), theme: ChatLayout.theme)
        header.stringValue = "?  Waiting for your reply"
        header.textColor = .systemOrange
        header.isHidden = !Self.isCard(item)
        card.isHidden = !Self.isCard(item)
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
        if Self.isCard(item) {
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
        copyButton.frame = NSRect(x: width - ChatLayout.side - 20, y: ChatLayout.gap + (Self.isCard(item) ? 6 : -2), width: 18, height: 18)
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

// MARK: The agent's work, folded

/// The notes and actions between your message and the agent's answer, as one row: a line with the number of steps
/// that opens to show them all. While the task works, it shows the latest note; once answered, it folds away.
final class ProcessRow: ListRowView {
    static let headerHeight: CGFloat = 22
    static let indent: CGFloat = 14
    static let bodyGap: CGFloat = 4

    private let header = NSButton()
    private let rule = NSView()
    private let body = MarkdownTextView()
    private var process: ChatProcess?
    var onToggle: ((UUID) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.isBordered = false
        header.imagePosition = .imageLeading
        header.alignment = .left
        header.target = self
        header.action = #selector(toggle)
        rule.wantsLayer = true
        body.linkHandler = { payload, _, _ in
            if case .url(let url) = payload { NSWorkspace.shared.open(url) }
        }
        for view in [rule, body, header] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// The Markdown under the header: everything when open, the latest note while live, nothing when folded.
    private static func bodyText(for process: ChatProcess) -> String? {
        if process.isExpanded { return process.markdown.isEmpty ? nil : process.markdown }
        return process.state == .live ? process.latestNote : nil
    }

    private static func bodyWidth(_ width: CGFloat) -> CGFloat { max(40, width - 2 * ChatLayout.side - indent) }

    static func height(for process: ChatProcess, width: CGFloat) -> CGFloat {
        var height = 2 * ChatLayout.gap + headerHeight
        if let text = bodyText(for: process) { height += bodyGap + MarkdownCache.height(for: text, width: bodyWidth(width), style: .steps) }
        return height
    }

    func show(_ process: ChatProcess) {
        self.process = process
        // While live, the progress line under the list shows the step and a running clock; this row adds the notes.
        let live = process.state == .live
        let title = if live { process.notes.isEmpty ? "Thinking" : process.steps == 1 ? "1 step" : "\(process.steps) steps" }
            else { process.summary }
        header.attributedTitle = NSAttributedString(string: " " + title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        header.image = NSImage(systemSymbolName: process.isExpanded ? "chevron.down" : "chevron.right",
                               accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        header.contentTintColor = .secondaryLabelColor
        header.toolTip = process.isExpanded ? "Hide the steps" : "Show the steps"
        if let text = Self.bodyText(for: process) {
            body.isHidden = false
            body.setContentImmediately(MarkdownCache.content(for: text, style: .steps), theme: ChatLayout.stepsTheme)
        } else {
            body.isHidden = true
        }
        rule.isHidden = !process.isExpanded || body.isHidden
        needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        body.textLabelView.clearSelection()
    }

    override func layout() {
        super.layout()
        guard let process else { return }
        let width = bounds.width
        let headerX = ChatLayout.side
        header.sizeToFit()
        header.frame = NSRect(x: headerX - 2, y: ChatLayout.gap, width: min(header.frame.width + 8, width - headerX - ChatLayout.side),
                              height: Self.headerHeight)
        guard let text = Self.bodyText(for: process) else { return }
        let bodyWidth = Self.bodyWidth(width)
        let y = ChatLayout.gap + Self.headerHeight + Self.bodyGap
        let height = MarkdownCache.height(for: text, width: bodyWidth, style: .steps)
        body.frame = NSRect(x: ChatLayout.side + Self.indent, y: y, width: bodyWidth, height: height)
        rule.frame = NSRect(x: ChatLayout.side + 4, y: y, width: 2, height: height)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rule.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func resetCursorRects() {
        addCursorRect(header.frame, cursor: .pointingHand)
    }

    @objc private func toggle() {
        guard let process else { return }
        onToggle?(process.id)
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
