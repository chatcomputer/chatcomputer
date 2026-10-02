import AppKit
import SwiftUI
import Virtualization

/// Window geometry shared by onboarding and the main view, so finishing setup never resizes the window:
/// the guest screen on the left at the guest display's aspect ratio, a fixed-width panel on the right.
enum WorkspaceMetrics {
    static let panelWidth: CGFloat = 380
    /// Default guest display: 2560×1600 pixels, 1280×800 points.
    static let guestAspect: CGFloat = 16.0 / 10.0
    static let largestStage = CGSize(width: 1280, height: 800)
    static let smallestStage = CGSize(width: 800, height: 500)
    /// Title bar (title + subtitle, no toolbar items while idle). The default window size includes it.
    static let chromeHeight: CGFloat = 28
    /// Space around the guest screen inside the left pane.
    static let stagePadding: CGFloat = 0

    static var minimumContentSize: CGSize {
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
    @ViewBuilder var stage: Stage
    @ViewBuilder var panel: Panel

    var body: some View {
        HStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            panel
                .frame(width: WorkspaceMetrics.panelWidth)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: WorkspaceMetrics.minimumContentSize.width, minHeight: WorkspaceMetrics.minimumContentSize.height)
    }
}

/// The guest display at its own aspect ratio, letterboxed in whatever space the window gives it.
/// Before a VM exists, the same rectangle shows a placeholder, so the layout looks the same.
struct GuestStage<Placeholder: View>: View {
    let virtualMachine: VZVirtualMachine?
    var aspectRatio: CGFloat = WorkspaceMetrics.guestAspect
    var agentHoldsInput = false
    var onUserIntervention: () -> Void = {}
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
