import AppKit
import ChatCore
import ListViewKit
import UniformTypeIdentifiers

/// The expanded right panel: who has control, the transcript, live progress, and the composer.
@MainActor
final class ChatViewController: NSViewController {
    let model: AppModel
    private let list = ListView<ChatItem>()
    private let header = ChatHeaderView()
    private let progress = ProgressBar()
    private let footer = ChatFooterView()
    private let attachments = AttachmentStrip()
    private let composer = Composer()
    private var observers: [Observing] = []
    private var showsSteps = UserDefaults.standard.bool(forKey: "showSteps")
    private var shownItems: [ChatItem] = []
    /// When the chat appeared: it settles at its final width just after (the panel expanding, the window fitting).
    private var appearedAt: Date?
    private var laidOutWidth: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = DropView()
        root.onDrop = { [weak self] urls in self?.model.attach(urls) }
        let stack = NSStackView(views: [header, separator(), list, progress, separator(), footer, attachments, composer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        list.setContentHuggingPriority(.init(1), for: .vertical)
        list.setContentCompressionResistancePriority(.init(1), for: .vertical)
        view = root

        let export: (URL) -> Void = { [weak model] url in model?.export(url) }
        list.rows {
            ListRow(MarkdownRow.self)
                .when { $0.role == .agent }
                .estimatedHeight(60)
                .height { item, context in MarkdownRow.height(for: item, width: context.width) }
                .configure { row, item, _ in row.onExport = export; row.show(item) }
            ListRow(TextRow.self)
                .estimatedHeight(28)
                .height { item, context in TextRow.height(for: item, width: context.width) }
                .configure { row, item, _ in row.onExport = export; row.show(item) }
        }

        header.onCollapse = { [weak model] in model?.setPanelCollapsed(true) }
        header.onCopyConversation = { [weak self] in self?.copyConversation() }
        header.onClearChat = { [weak model] in model?.clearChat() }
        footer.showsSteps = showsSteps
        footer.onToggleSteps = { [weak self] in self?.toggleSteps($0) }
        footer.onSharedFolders = { [weak model] in model?.showingSharedFolders = true }
        footer.onSnapshots = { [weak model] in model?.showingSnapshots = true }
        attachments.onRemove = { [weak model] url in model?.pendingAttachments.removeAll { $0 == url } }
        composer.onAttach = { [weak model] in model?.chooseAttachments() }
        composer.onSend = { [weak model] text in model?.submit(text) ?? false }

        observers.append(Observing { [weak self] in self?.updateTranscript() })
        observers.append(Observing { [weak self] in self?.updateChrome() })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // A restored chat opens at its latest message.
        settleAtBottom()
        appearedAt = Date()
        view.window?.makeFirstResponder(composer.textView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Rows re-wrap when the width settles after appearing; land on the latest message again.
        guard view.bounds.width != laidOutWidth else { return }
        laidOutWidth = view.bounds.width
        guard let appearedAt, Date().timeIntervalSince(appearedAt) < 1 else { return }
        // After the list has laid out its rows at the new width.
        DispatchQueue.main.async { [weak self] in self?.settleAtBottom() }
    }

    /// Jumps to the end without animation. Rows off screen only have estimated heights until they are measured, so
    /// one jump lands at the estimated end; measuring the rows there moves it. Repeat until it holds.
    private func settleAtBottom() {
        for _ in 0..<8 {
            list.scrollToBottom(animated: false)
            list.layoutSubtreeIfNeeded()
            if list.isScrolledToBottom(tolerance: 1) { break }
        }
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: Updates

    private func updateTranscript() {
        let items = showsSteps ? model.transcript : model.transcript.filter { $0.role != .action }
        guard items != shownItems else { return }
        let following = list.isScrolledToBottom(tolerance: 40) || shownItems.isEmpty
        let appendedByUser = items.last?.role == .user && items.last?.id != shownItems.last?.id
        let isAppend = items.count >= shownItems.count && Array(items.prefix(shownItems.count)) == shownItems
        if isAppend {
            list.append(contentsOf: items.dropFirst(shownItems.count))
        } else {
            list.apply(items)
        }
        shownItems = items
        if following || appendedByUser, !list.isUserInteractingWithScroll {
            if isAppend { list.scrollToBottom(animated: true) } else { settleAtBottom() }
        }
    }

    private func updateChrome() {
        header.show(ControlState(model))
        progress.show(model.phase == .running ? model.progress : nil)
        footer.show(phase: phaseText, help: phaseHelp, tokens: model.tokens, cached: model.cachedTokens)
        attachments.show(model.pendingAttachments)
        composer.placeholder = { if case .waitingForUser = model.phase { return "Reply to the agent…" } else { return "What should your computer do?" } }()
    }

    private func toggleSteps(_ on: Bool) {
        showsSteps = on
        UserDefaults.standard.set(on, forKey: "showSteps")
        updateTranscript()
    }

    private func copyConversation() {
        let text = model.transcript.map { item -> String in
            switch item.role {
            case .user: "**You:** \(item.text)"
            case .agent: item.text
            case .action: "`\(item.text)`"
            case .system, .status: "_\(item.text)_"
            }
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var phaseText: String {
        switch model.phase {
        case .ready: "Ready"
        case .running: "Working"
        case .waitingForUser: "Waiting for your reply"
        case .waitingExternal: "Waiting"
        case .paused: "Paused"
        case .takenOver: "You have control"
        case .failed: "Stopped"
        case .completed: "Done"
        case .cancelled: "Cancelled"
        }
    }

    private var phaseHelp: String {
        switch model.phase {
        case .waitingForUser(let reason), .waitingExternal(let reason, _): reason
        case .failed(let reason): reason
        default: phaseText
        }
    }
}

// MARK: Header

final class ChatHeaderView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let more = NSButton()
    private let collapse = NSButton()
    var onCollapse: (() -> Void)?
    var onCopyConversation: (() -> Void)?
    var onClearChat: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        for (button, symbol, tip) in [(more, "ellipsis.circle", "More"), (collapse, "sidebar.right", "Hide Chat (⌃⌘S): keep only the controls")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.toolTip = tip
            button.target = self
            button.contentTintColor = .secondaryLabelColor
        }
        more.action = #selector(showMenu(_:))
        collapse.action = #selector(collapse(_:))
        let stack = NSStackView(views: [icon, title, NSView(), more, collapse])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ control: ControlState) {
        icon.image = NSImage(systemSymbolName: control.symbol, accessibilityDescription: nil)
        icon.contentTintColor = control.isAgent ? .controlAccentColor : .secondaryLabelColor
        title.stringValue = control.title
        title.textColor = control.isAgent ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func collapse(_ sender: Any?) { onCollapse?() }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Conversation", action: #selector(copyConversation), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Chat", action: #selector(clearChat), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func copyConversation() { onCopyConversation?() }
    @objc private func clearChat() { onClearChat?() }
}

// MARK: Progress

/// "Step 6 of 60 · thinking… 12 s", or the step just taken, while the agent works.
final class ProgressBar: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private var progress: TaskProgress?
    private var timer: Timer?
    private var height: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), height,
        ])
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ progress: TaskProgress?) {
        self.progress = progress
        height.constant = progress == nil ? 0 : 30
        if progress == nil {
            spinner.stopAnimation(nil)
            timer?.invalidate()
            timer = nil
        } else {
            spinner.startAnimation(nil)
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        }
        refresh()
    }

    private func refresh() {
        guard let progress else { label.stringValue = ""; return }
        let step = "Step \(progress.turn) of \(progress.maxTurns)"
        if let since = progress.waitingSince {
            label.stringValue = "\(step) · thinking… \(max(0, Int(Date().timeIntervalSince(since)))) s"
        } else {
            label.stringValue = "\(step) · \(progress.lastAction ?? "working")"
        }
    }
}

// MARK: Footer

final class ChatFooterView: NSView {
    private let phase = NSTextField(labelWithString: "")
    private let steps = NSSwitch()
    private let tokens = NSTextField(labelWithString: "")
    var showsSteps = false { didSet { steps.state = showsSteps ? .on : .off } }
    var onToggleSteps: ((Bool) -> Void)?
    var onSharedFolders: (() -> Void)?
    var onSnapshots: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for field in [phase, tokens] {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
        }
        tokens.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        phase.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let folders = iconButton("folder", "Shared folders: folders from this Mac, the inbox and the outbox (⌥⌘F)", #selector(sharedFolders))
        let snapshots = iconButton("clock.arrow.circlepath", "Snapshots: save the virtual Mac and return to it later (⇧⌘S)", #selector(snapshotsTapped))
        steps.controlSize = .mini
        steps.target = self
        steps.action = #selector(toggle)
        let stepsLabel = NSTextField(labelWithString: "Steps")
        stepsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stepsLabel.textColor = .secondaryLabelColor
        steps.toolTip = "Show every click and key press"
        let stack = NSStackView(views: [phase, NSView(), folders, snapshots, steps, stepsLabel, tokens])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    func show(phase text: String, help: String, tokens count: (input: Int, output: Int), cached: Int) {
        phase.stringValue = text
        phase.toolTip = help
        tokens.stringValue = "\(count.input + count.output) tokens"
        tokens.toolTip = count.input > 0
            ? "\(count.input) in (\(cached * 100 / max(count.input, 1))% from the provider's cache), \(count.output) out"
            : "No model requests yet"
    }

    @objc private func toggle() { onToggleSteps?(steps.state == .on) }
    @objc private func sharedFolders() { onSharedFolders?() }
    @objc private func snapshotsTapped() { onSnapshots?() }
}

// MARK: Attachments

final class AttachmentStrip: NSView {
    private let stack = NSStackView()
    private var height: NSLayoutConstraint!
    private var urls: [URL] = []
    var onRemove: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor), height,
        ])
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ urls: [URL]) {
        guard urls != self.urls else { return }
        self.urls = urls
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, url) in urls.enumerated() {
            let button = NSButton(title: url.lastPathComponent, image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")!,
                                  target: self, action: #selector(remove(_:)))
            button.tag = index
            button.imagePosition = .imageTrailing
            button.bezelStyle = .push
            button.controlSize = .small
            button.toolTip = "Remove \(url.lastPathComponent)"
            stack.addArrangedSubview(button)
        }
        height.constant = urls.isEmpty ? 0 : 34
    }

    @objc private func remove(_ sender: NSButton) {
        guard urls.indices.contains(sender.tag) else { return }
        onRemove?(urls[sender.tag])
    }
}

// MARK: Composer

/// The message field: grows to six lines, Return sends, Shift- or Option-Return adds a line.
final class Composer: NSView, NSTextViewDelegate {
    let textView = ComposerTextView()
    private let scroll = NSScrollView()
    private let attach = NSButton()
    private let send = NSButton()
    private var textHeight: NSLayoutConstraint!
    var onSend: ((String) -> Bool)?
    var onAttach: (() -> Void)?
    var placeholder = "" { didSet { textView.placeholder = placeholder } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.delegate = self
        textView.onReturn = { [weak self] in self?.submit() }
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        for (button, symbol, tip) in [(attach, "paperclip", "Attach files to the next task; they go into its inbox, read-only in the virtual Mac"),
                                      (send, "arrow.up.circle.fill", "Send")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            button.isBordered = false
            button.toolTip = tip
            button.target = self
        }
        attach.contentTintColor = .secondaryLabelColor
        attach.action = #selector(attachTapped)
        send.action = #selector(sendTapped)
        for view in [attach, scroll, send] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textHeight = scroll.heightAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([
            attach.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            attach.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -2),
            scroll.leadingAnchor.constraint(equalTo: attach.trailingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            send.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            send.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -2),
            textHeight,
        ])
        updateSendButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func textDidChange(_ notification: Notification) {
        updateSendButton()
        textView.needsDisplay = true
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13))
        let used = layout.usedRect(for: container).height + 8
        textHeight.constant = min(max(used, lineHeight + 8), lineHeight * 6 + 8)
    }

    private func updateSendButton() {
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.isEnabled = !empty
        send.contentTintColor = empty ? .tertiaryLabelColor : .controlAccentColor
    }

    private func submit() {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if onSend?(text) == true {
            textView.string = ""
            textDidChange(Notification(name: NSText.didChangeNotification))
        }
    }

    @objc private func sendTapped() { submit() }
    @objc private func attachTapped() { onAttach?() }
}

final class ComposerTextView: NSTextView {
    var onReturn: (() -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection([.shift, .option, .command, .control])
        if isReturn, modifiers.isEmpty, !hasMarkedText() {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]
        placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attributes)
    }
}

// MARK: Drop target

/// Files dropped on the chat are attached to the next task; folders are shared.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var isTargeted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTargeted = !urls(sender).isEmpty
        return isTargeted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        let dropped = urls(sender)
        guard !dropped.isEmpty else { return false }
        onDrop?(dropped)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isTargeted else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), xRadius: 8, yRadius: 8)
        path.lineWidth = 3
        path.stroke()
        let text = "Drop files to attach them, or folders to share them"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
