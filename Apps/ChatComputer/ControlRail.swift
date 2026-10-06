import SwiftUI

/// Who controls the virtual Mac's input, for the rail and the panel header.
struct ControlState {
    let title: String
    let symbol: String
    let isAgent: Bool

    @MainActor init(_ model: AppModel) {
        if let holder = model.externalHolder {
            self.init(title: "\(holder) has control", symbol: "terminal.fill", isAgent: true)
        } else if let blocked = model.externalBlockedBy {
            self.init(title: "You took over from \(blocked)", symbol: "person.fill", isAgent: false)
        } else if model.phase == .running {
            self.init(title: "The agent has control", symbol: "sparkles", isAgent: true)
        } else {
            self.init(title: "You have control", symbol: "person.fill", isAgent: false)
        }
    }

    private init(title: String, symbol: String, isAgent: Bool) {
        self.title = title
        self.symbol = symbol
        self.isAgent = isAgent
    }
}

/// The collapsed panel: a column of the controls that matter while something else drives the virtual Mac.
struct ControlRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let control = ControlState(model)
        VStack(spacing: 6) {
            RailButton(title: "Show Chat (⌃⌘S)", symbol: "sidebar.right") { model.setPanelCollapsed(false) }
                .overlay(alignment: .topTrailing) {
                    if model.unreadMessageCount > 0 || isWaitingForUser {
                        Circle().fill(isWaitingForUser ? Color.orange : Color.accentColor)
                            .frame(width: 9, height: 9)
                            .offset(x: -6, y: 6)
                    }
                }
            Divider().frame(width: 28).padding(.vertical, 4)

            Image(systemName: control.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(control.isAgent ? Color.accentColor : .secondary)
                .frame(width: 36, height: 32)
                .help(control.title)

            switch model.phase {
            case .running:
                RailButton(title: "Pause Agent (⌘.)", symbol: "pause.fill") { model.pause() }
            case .paused:
                RailButton(title: "Continue", symbol: "play.fill") { model.resume() }
            default:
                EmptyView()
            }
            if model.phase == .takenOver || model.externalBlockedBy != nil {
                RailButton(title: model.externalBlockedBy.map { "Hand Back to \($0)" } ?? "Hand Back Control", symbol: "hand.raised") {
                    model.returnControl()
                }
            } else if control.isAgent {
                RailButton(title: "Take Over (⇧⌘T)", symbol: "hand.raised.fill") { model.takeOver() }
            }

            Spacer()

            RailButton(title: model.snapshotsUnavailableReason ?? "Take Snapshot (⌥⌘S)", symbol: "camera") {
                Task { await model.takeSnapshot() }
            }
            .disabled(!model.canManageSnapshots)
            RailButton(title: "Snapshots (⇧⌘S)", symbol: "clock.arrow.circlepath") { model.showingSnapshots = true }
            RailButton(title: "Shared Folders (⌥⌘F)", symbol: "folder") { model.showingSharedFolders = true }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var isWaitingForUser: Bool {
        if case .waitingForUser = model.phase { return true }
        return false
    }
}

private struct RailButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 36, height: 32)
                .background(isHovering ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 7))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .onHover { isHovering = $0 }
    }
}
