import AppKit
import Virtualization

/// The live guest screen (`GuestStageView` lays it out). `VZVirtualMachineView` handles the framebuffer and manual
/// input; it is not a semantic automation API (the agent observes through the guest driver instead).
///
/// While the agent holds input, a transparent shield sits on top. Any click or key press on it
/// is treated as the user taking over (proposal §04), and only then does input reach the guest.
final class VMContainerView: NSView {
    let machineView = VZVirtualMachineView()
    let shield = InputShieldView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        machineView.capturesSystemKeys = true
        // Keep the guest at its configured resolution and scale it to fit. Following the pane's size would
        // change the guest resolution on every window resize, and with it the agent's screenshot coordinates.
        machineView.automaticallyReconfiguresDisplay = false
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
    var onIntervention: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()
    }

    // Deliberate input only. Scrolling is ignored: trackpad momentum or a scroll aimed at the chat
    // panel can drift over the guest screen without the user meaning to take over.
    override func mouseDown(with event: NSEvent) { intervene("you clicked the virtual Mac") }
    override func rightMouseDown(with event: NSEvent) { intervene("you right-clicked the virtual Mac") }
    override func keyDown(with event: NSEvent) { intervene("you pressed a key while the virtual Mac had focus") }

    private func intervene(_ reason: String) {
        isHidden = true
        onIntervention?(reason)
    }
}
