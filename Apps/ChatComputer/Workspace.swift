import AppKit
import SwiftUI
import Virtualization

/// Window geometry shared by onboarding and the main view, so finishing setup never resizes the window:
/// the guest screen on the left at the guest display's aspect ratio, a fixed-width panel on the right.
enum WorkspaceMetrics {
    static let panelWidth: CGFloat = 380
    /// The collapsed panel: a column of controls.
    static let railWidth: CGFloat = 52
    /// Default guest display: 2560×1600 pixels, 1280×800 points.
    static let guestAspect: CGFloat = 16.0 / 10.0
    static let largestStage = CGSize(width: 1280, height: 800)
    static let smallestStage = CGSize(width: 800, height: 500)
    /// Title bar with its toolbar (always shown, so its height never changes). The default window size includes it.
    static let chromeHeight: CGFloat = 52
    /// Space around the guest screen inside the left pane.
    static let stagePadding: CGFloat = 0

    static var minimumContentSize: CGSize { minimumContentSize(panelWidth: panelWidth) }

    static func minimumContentSize(panelWidth: CGFloat) -> CGSize {
        CGSize(width: smallestStage.width + 2 * stagePadding + 1 + panelWidth, height: smallestStage.height + 2 * stagePadding)
    }

    /// The largest stage that fits on the main screen with some margin, without exceeding 1280×800.
    static var defaultContentSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let widthLimit = visible.width * 0.92 - panelWidth - 1 - 2 * stagePadding
        let heightLimit = (visible.height * 0.9 - chromeHeight - 2 * stagePadding) * guestAspect
        let stageWidth = max(smallestStage.width, min(largestStage.width, widthLimit, heightLimit)).rounded()
        // The toolbar is part of the content area, so the stage fits exactly with no letterbox at the default size.
        return CGSize(width: stageWidth + 2 * stagePadding + 1 + panelWidth,
                      height: (stageWidth / guestAspect).rounded() + 2 * stagePadding + chromeHeight)
    }
}

/// Guest screen on the left, a fixed-width panel on the right.
struct Workspace<Stage: View, Panel: View>: View {
    var panelWidth = WorkspaceMetrics.panelWidth
    @ViewBuilder var stage: Stage
    @ViewBuilder var panel: Panel

    var body: some View {
        HStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            panel
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: WorkspaceMetrics.minimumContentSize(panelWidth: panelWidth).width,
               minHeight: WorkspaceMetrics.minimumContentSize.height)
        .background(WindowFitter(panelWidth: panelWidth))
    }
}

/// Keeps the window's height matched to the guest screen's aspect ratio, so the guest fills the left pane with
/// no bars beside or above it: after a resize by the user, when the window first appears, and when the panel
/// collapses or expands. During a live resize the stage letterboxes briefly; the height snaps when it ends.
private struct WindowFitter: NSViewRepresentable {
    var panelWidth: CGFloat

    func makeNSView(context: Context) -> FitterView { FitterView() }

    func updateNSView(_ view: FitterView, context: Context) {
        view.panelWidth = panelWidth
        DispatchQueue.main.async { view.fit() }
    }

    final class FitterView: NSView {
        var panelWidth: CGFloat = WorkspaceMetrics.panelWidth
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit() }
            }
            DispatchQueue.main.async { self.fit() }
        }

        func fit() {
            guard let window, !window.styleMask.contains(.fullScreen), !window.inLiveResize else { return }
            let content = window.contentLayoutRect.size
            let stageWidth = content.width - panelWidth - 1
            guard stageWidth > 0 else { return }
            let delta = (stageWidth / WorkspaceMetrics.guestAspect).rounded() - content.height
            guard abs(delta) >= 1 else { return }
            var frame = window.frame
            frame.size.height += delta
            frame.origin.y -= delta   // keep the top edge where it is
            if let screen = window.screen?.visibleFrame, frame.minY < screen.minY {
                // Too tall for the screen: narrow the window instead.
                let excess = screen.minY - frame.minY
                frame.origin.y += excess
                frame.size.height -= excess
                frame.size.width -= (excess * WorkspaceMetrics.guestAspect).rounded()
            }
            window.setFrame(frame, display: true, animate: false)
        }

    }
}

/// The guest display at its own aspect ratio, letterboxed in whatever space the window gives it.
/// Before a VM exists, the same rectangle shows a placeholder, so the layout looks the same.
struct GuestStage<Placeholder: View>: View {
    let virtualMachine: VZVirtualMachine?
    var aspectRatio: CGFloat = WorkspaceMetrics.guestAspect
    var agentHoldsInput = false
    var onUserIntervention: (String) -> Void = { _ in }
    var onViewReady: (VZVirtualMachineView) -> Void = { _ in }
    @ViewBuilder var placeholder: Placeholder

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            Group {
                if let virtualMachine {
                    VMDisplayView(virtualMachine: virtualMachine, agentHoldsInput: agentHoldsInput,
                                  onUserIntervention: onUserIntervention, onViewReady: onViewReady)
                } else {
                    placeholder
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .padding(WorkspaceMetrics.stagePadding)
        }
    }
}

/// What the guest screen shows before the VM has booted.
struct GuestPlaceholder: View {
    let title: String
    var detail = ""
    var progress: Double?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.42), Color(red: 0.08, green: 0.09, blue: 0.24)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                if !detail.isEmpty {
                    Text(detail).font(.callout).foregroundStyle(.white.opacity(0.7))
                }
                if let progress {
                    ProgressView(value: progress).frame(width: 260).tint(.white)
                }
            }
            .padding(32)
        }
    }
}
