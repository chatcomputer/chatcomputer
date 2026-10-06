import AppKit
import SwiftUI

/// The one main window, in AppKit: the guest screen on the left, a panel on the right (the setup steps, then the chat
/// or its rail), and a toolbar.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let model: AppModel
    private var observers: [Observing] = []
    private let toolbarItems = ToolbarItems()

    init(model: AppModel) {
        self.model = model
        let size = WorkspaceMetrics.defaultContentSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Chat Computer"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let content = WorkspaceViewController(model: model)
        // The bridge hosts what is still SwiftUI: sheets, the error alert, opening Settings, start-up work.
        let bridge = NSHostingView(rootView: SceneBridge().environment(model))
        bridge.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        content.view.addSubview(bridge)
        window.contentViewController = content
        window.setContentSize(size)

        observers.append(Observing { [weak self] in self?.updateChrome() })
        // Finishing setup can change the guest's shape; collapsing the panel resizes the window itself.
        observers.append(Observing { [weak self] in _ = self?.model.isReady; self?.fitHeightToGuest() })

        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")
        fitHeightToGuest()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Title and toolbar

    private func updateChrome() {
        guard let window else { return }
        window.subtitle = model.isReady ? statusText : "Setting up · step \(model.onboarding.step.rawValue + 1) of \(OnboardingState.Step.allCases.count)"
        toolbarItems.update(model)
    }

    private var statusText: String {
        if let activity = model.snapshotActivity { return activity.title }
        let vmState = switch model.vm?.state {
        case .running: "Running"
        case .starting: "Starting"
        case .paused: "Paused"
        case .saving: "Saving"
        case .error(let message): "Error: \(message)"
        case .stopped, nil: "Stopped"
        }
        if model.updatingAgent { return "\(vmState) · Updating the agent in the virtual Mac…" }
        if model.vm?.state == .running, let problem = model.guestReadiness?.problem {
            return "\(vmState) · Not ready: \(problem)"
        }
        let holder = if let external = model.externalHolder { "\(external) has control" }
            else if model.phase == .running { "Agent has control" } else { "You have control" }
        return "\(vmState) · \(holder)"
    }

    // MARK: Geometry

    private var panelWidth: CGFloat {
        model.isReady && model.isPanelCollapsed ? WorkspaceMetrics.railWidth : WorkspaceMetrics.panelWidth
    }

    /// The window height that shows the guest screen at its aspect ratio for this window width: no bars beside it.
    private func fittedSize(for frameSize: NSSize) -> NSSize {
        guard let window else { return frameSize }
        let chromeWidth = window.frame.width - window.contentLayoutRect.width
        let chromeHeight = window.frame.height - window.contentLayoutRect.height
        let minimum = WorkspaceMetrics.minimumContentSize(panelWidth: panelWidth)
        let width = max(frameSize.width, minimum.width + chromeWidth)
        let stageWidth = width - chromeWidth - panelWidth - 1
        return NSSize(width: width, height: (stageWidth / model.guestAspectRatio).rounded() + chromeHeight)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        sender.styleMask.contains(.fullScreen) ? frameSize : fittedSize(for: frameSize)
    }

    /// Corrects the height after anything else changed the width (first launch, the panel collapsing).
    private func fitHeightToGuest() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let size = self.fittedSize(for: window.frame.size)
            guard abs(size.height - window.frame.height) >= 1 || abs(size.width - window.frame.width) >= 1 else { return }
            var frame = window.frame
            frame.origin.y += frame.height - size.height   // keep the top edge where it is
            frame.size = size
            if let screen = window.screen?.visibleFrame, frame.minY < screen.minY {
                let excess = screen.minY - frame.minY
                frame.origin.y += excess
                frame.size.height -= excess
                frame.size.width -= (excess * self.model.guestAspectRatio).rounded()
            }
            window.setFrame(frame, display: true, animate: false)
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + ToolbarItems.identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        toolbarItems.item(identifier, model: model)
    }
}

/// The toolbar's buttons. The snapshot and chat buttons are always there, so the title bar keeps one height: a toolbar
/// that appeared with a task would shrink the guest screen and leave bars beside it.
@MainActor
private final class ToolbarItems {
    static let control = NSToolbarItem.Identifier("control")
    static let handBack = NSToolbarItem.Identifier("handBack")
    static let cancel = NSToolbarItem.Identifier("cancel")
    static let snapshot = NSToolbarItem.Identifier("snapshot")
    static let chat = NSToolbarItem.Identifier("chat")
    static let identifiers = [control, handBack, cancel, snapshot, chat]

    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private weak var model: AppModel?

    func item(_ identifier: NSToolbarItem.Identifier, model: AppModel) -> NSToolbarItem? {
        self.model = model
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = true
        item.target = self
        item.action = #selector(perform(_:))
        items[identifier] = item
        update(model)
        return item
    }

    func update(_ model: AppModel) {
        set(Self.snapshot, title: "Take Snapshot", symbol: "camera", tip: model.snapshotsUnavailableReason ?? "Save the whole virtual Mac now (⌥⌘S)",
            hidden: !model.isReady, enabled: model.canManageSnapshots)
        let chatTitle = model.isPanelCollapsed ? "Show Chat" : "Hide Chat"
        set(Self.chat, title: chatTitle, symbol: "sidebar.right",
            tip: model.isPanelCollapsed ? "Show Chat (⌃⌘S)" : "Hide Chat (⌃⌘S): keep only the controls", hidden: !model.isReady)
        switch model.phase {
        case .running:
            set(Self.control, title: "Pause", symbol: "pause.fill", tip: "Pause the agent (⌘.)", hidden: false)
        case .paused:
            set(Self.control, title: "Continue", symbol: "play.fill", tip: "Continue the task", hidden: false)
        default:
            if let holder = model.externalHolder {
                set(Self.control, title: "Take over from \(holder)", symbol: "hand.raised.fill", tip: "Take over from \(holder)", hidden: false)
            } else {
                set(Self.control, title: "Control", symbol: "pause.fill", tip: "", hidden: true)
            }
        }
        let handBackTitle = model.externalBlockedBy.map { "Hand back to \($0)" } ?? "Hand back control"
        set(Self.handBack, title: handBackTitle, symbol: "hand.raised", tip: handBackTitle,
            hidden: !(model.phase == .takenOver || model.externalBlockedBy != nil))
        set(Self.cancel, title: "Cancel task", symbol: "xmark", tip: "Cancel the task",
            hidden: model.phase.isTerminal || model.phase == .ready)
    }

    private func set(_ identifier: NSToolbarItem.Identifier, title: String, symbol: String, tip: String, hidden: Bool, enabled: Bool = true) {
        guard let item = items[identifier] else { return }
        item.label = title
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.isHidden = hidden
        item.isEnabled = enabled
    }

    @objc private func perform(_ sender: NSToolbarItem) {
        guard let model else { return }
        switch sender.itemIdentifier {
        case Self.snapshot: Task { await model.takeSnapshot() }
        case Self.chat: model.setPanelCollapsed(!model.isPanelCollapsed)
        case Self.cancel: model.cancel()
        case Self.handBack: model.returnControl()
        case Self.control:
            switch model.phase {
            case .running: model.pause()
            case .paused: model.resume()
            default: model.takeOver()
            }
        default: break
        }
    }
}

/// What remains SwiftUI around the AppKit window: the two sheets, the error alert, opening Settings (SwiftUI only
/// opens it from a view) and the work that starts once the window is up.
private struct SceneBridge: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .sheet(isPresented: Bindable(model).showingSnapshots) {
                SnapshotsSheet().environment(model)
            }
            .sheet(isPresented: Bindable(model).showingSharedFolders) {
                SharedFoldersSheet().environment(model)
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .onChange(of: model.settingsRequest) { openSettings() }
            .task(id: model.isReady) {
                // Again when setup finishes: boot the new machine and start any development task.
                guard model.isReady else { return }
                if model.vm?.state == .stopped { await model.bootVM() }
                await model.startDevelopmentTaskIfRequested()
                await model.continueRestoredTaskIfRequested()
            }
    }
}
