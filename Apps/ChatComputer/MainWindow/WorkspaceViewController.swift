import AppKit
import SwiftUI
import Virtualization

/// The set-up machine's window content: the guest screen on the left, a fixed-width panel on the right (the chat,
/// or the rail of controls when it is collapsed).
@MainActor
final class WorkspaceViewController: NSViewController {
    let model: AppModel
    private let stage: GuestStageView
    private let panel = NSView()
    private var panelWidth: NSLayoutConstraint!
    private var chat: ChatViewController?
    private var rail: NSView?
    private var observers: [Observing] = []

    init(model: AppModel) {
        self.model = model
        stage = GuestStageView(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        let divider = NSBox()
        divider.boxType = .separator
        for view in [stage, divider, panel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        panelWidth = panel.widthAnchor.constraint(equalToConstant: WorkspaceMetrics.panelWidth)
        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stage.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: stage.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            panel.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panelWidth,
        ])
        let minimum = WorkspaceMetrics.minimumContentSize(panelWidth: WorkspaceMetrics.railWidth)
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum.width).isActive = true
        root.heightAnchor.constraint(greaterThanOrEqualToConstant: minimum.height).isActive = true
        view = root
        observers.append(Observing { [weak self] in self?.updatePanel() })
    }

    private func updatePanel() {
        let collapsed = model.isPanelCollapsed
        panelWidth.constant = collapsed ? WorkspaceMetrics.railWidth : WorkspaceMetrics.panelWidth
        if collapsed {
            if chat != nil { chat?.view.removeFromSuperview(); chat?.removeFromParent(); chat = nil }
            if rail == nil {
                let hosting = NSHostingView(rootView: ControlRail().environment(model))
                embed(hosting)
                rail = hosting
            }
        } else {
            if rail != nil { rail?.removeFromSuperview(); rail = nil }
            if chat == nil {
                let controller = ChatViewController(model: model)
                addChild(controller)
                embed(controller.view)
                chat = controller
            }
        }
    }

    private func embed(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            view.topAnchor.constraint(equalTo: panel.topAnchor),
            view.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
    }
}

/// The guest display at its own aspect ratio, centred in whatever space the window gives it, with the placeholder
/// before the machine exists and the frozen last frame while a snapshot is taken or restored.
@MainActor
final class GuestStageView: NSView {
    private let model: AppModel
    private let display = VMContainerView()
    private let placeholder: NSHostingView<AnyView>
    private var overlay: NSHostingView<AnyView>?
    private var observers: [Observing] = []

    init(model: AppModel) {
        self.model = model
        placeholder = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        addSubview(display)
        addSubview(placeholder)
        display.shield.onIntervention = { [weak model] reason in model?.takeOver(reason: reason) }
        model.guestView = display.machineView
        observers.append(Observing { [weak self] in self?.update() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        let machine = model.vm?.virtualMachine
        if display.machineView.virtualMachine !== machine { display.machineView.virtualMachine = machine }
        display.isHidden = machine == nil
        placeholder.isHidden = machine != nil
        if machine == nil {
            let title = model.vm?.state == .starting ? "Starting your virtual Mac…" : "Your virtual Mac is off"
            placeholder.rootView = AnyView(GuestPlaceholder(title: title))
        }
        let holds = model.agentHoldsInput
        display.shield.isHidden = !holds
        if holds { window?.makeFirstResponder(display.shield) }

        if let activity = model.snapshotActivity {
            if overlay == nil {
                let view = NSHostingView(rootView: AnyView(SnapshotActivityOverlay(activity: activity)))
                view.alphaValue = 0
                addSubview(view)
                overlay = view
                NSAnimationContext.runAnimationGroup { $0.duration = 0.2; view.animator().alphaValue = 1 }
            } else {
                overlay?.rootView = AnyView(SnapshotActivityOverlay(activity: activity))
            }
        } else if let view = overlay {
            overlay = nil
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; view.animator().alphaValue = 0 }) { view.removeFromSuperview() }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let aspect = model.guestAspectRatio
        var size = bounds.size
        if size.width / max(size.height, 1) > aspect { size.width = (size.height * aspect).rounded() }
        else { size.height = (size.width / aspect).rounded() }
        let rect = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
        display.frame = rect
        placeholder.frame = rect
        overlay?.frame = rect
    }
}
