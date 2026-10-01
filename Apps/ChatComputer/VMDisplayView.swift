import AppKit
import SwiftUI
import Virtualization

/// Left pane: the live guest screen. `VZVirtualMachineView` handles framebuffer and manual input;
/// it is not a semantic automation API (the agent observes through the guest driver instead).
///
/// While the agent holds input, a transparent shield sits on top. Any click or key press on it
/// is treated as the user taking over (proposal §04), and only then does input reach the guest.
struct VMDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine?
    let agentHoldsInput: Bool
    let onUserIntervention: () -> Void

    func makeNSView(context: Context) -> VMContainerView {
        VMContainerView()
    }

    func updateNSView(_ view: VMContainerView, context: Context) {
        if view.machineView.virtualMachine !== virtualMachine {
            view.machineView.virtualMachine = virtualMachine
        }
        view.shield.isHidden = !agentHoldsInput
        view.shield.onIntervention = onUserIntervention
        if agentHoldsInput { view.window?.makeFirstResponder(view.shield) }
    }
}

final class VMContainerView: NSView {
    let machineView = VZVirtualMachineView()
    let shield = InputShieldView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        machineView.capturesSystemKeys = true
        machineView.automaticallyReconfiguresDisplay = true
        for view in [machineView, shield] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class InputShieldView: NSView {
    var onIntervention: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) { intervene() }
    override func rightMouseDown(with event: NSEvent) { intervene() }
    override func keyDown(with event: NSEvent) { intervene() }
    override func scrollWheel(with event: NSEvent) { intervene() }

    private func intervene() {
        isHidden = true
        onIntervention?()
    }
}
