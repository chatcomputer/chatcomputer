import AppKit
import SwiftUI

/// Main window geometry, the same during setup and after, so finishing setup never resizes the window:
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

    static var minimumContentSize: CGSize { minimumContentSize(panelWidth: panelWidth) }

    static func minimumContentSize(panelWidth: CGFloat) -> CGSize {
        CGSize(width: smallestStage.width + 1 + panelWidth, height: smallestStage.height)
    }

    /// The largest stage that fits on the main screen with some margin, without exceeding 1280×800.
    static var defaultContentSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let widthLimit = visible.width * 0.92 - panelWidth - 1
        let heightLimit = (visible.height * 0.9 - chromeHeight) * guestAspect
        let stageWidth = max(smallestStage.width, min(largestStage.width, widthLimit, heightLimit)).rounded()
        // The toolbar is part of the content area, so the stage fits exactly with no letterbox at the default size.
        return CGSize(width: stageWidth + 1 + panelWidth,
                      height: (stageWidth / guestAspect).rounded() + chromeHeight)
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
