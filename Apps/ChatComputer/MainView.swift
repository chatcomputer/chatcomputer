import ChatCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isReady {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Guest desktop on the left at its own aspect ratio, host chat on the right (same geometry as onboarding).
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Workspace(panelWidth: model.isPanelCollapsed ? WorkspaceMetrics.railWidth : WorkspaceMetrics.panelWidth) {
            GuestStage(virtualMachine: model.vm?.virtualMachine, aspectRatio: model.guestAspectRatio,
                       agentHoldsInput: model.agentHoldsInput, onUserIntervention: { model.takeOver(reason: $0) },
                       onViewReady: { model.guestView = $0 }) {
                GuestPlaceholder(title: model.vm?.state == .starting ? "Starting your virtual Mac…" : "Your virtual Mac is off")
            }
            // The VM stops and starts again while a snapshot is taken or restored; keep its last frame up meanwhile.
            .overlay {
                if let activity = model.snapshotActivity { SnapshotActivityOverlay(activity: activity) }
            }
            .animation(.easeInOut(duration: 0.2), value: model.snapshotActivity != nil)
        } panel: {
            if model.isPanelCollapsed { ControlRail() } else { ChatPanel() }
        }
        // Status is plain text in the window subtitle; a toolbar item would render as a clickable-looking capsule.
        .navigationTitle("Chat Computer")
        .navigationSubtitle(statusText)
        .toolbar {
            ToolbarItemGroup {
                switch model.phase {
                case .running:
                    Button("Pause", systemImage: "pause.fill") { model.pause() }
                case .paused:
                    Button("Continue", systemImage: "play.fill") { model.resume() }
                case .takenOver:
                    Button("Hand back control", systemImage: "hand.raised") { model.returnControl() }
                default:
                    if let holder = model.externalHolder {
                        Button("Take over from \(holder)", systemImage: "hand.raised.fill") { model.takeOver() }
                    } else if let blocked = model.externalBlockedBy {
                        Button("Hand back to \(blocked)", systemImage: "hand.raised") { model.returnControl() }
                    }
                }
                if !model.phase.isTerminal, model.phase != .ready {
                    Button("Cancel task", systemImage: "xmark") { model.cancel() }
                }
            }
            // Always there, so the title bar keeps one height: a toolbar that appears with a task would shrink the
            // guest screen and leave bars beside it.
            ToolbarItem {
                Button("Take Snapshot", systemImage: "camera") { Task { await model.takeSnapshot() } }
                    .help("Save the whole virtual Mac now (⌥⌘S)")
                    .disabled(!model.canManageSnapshots)
            }
        }
        .sheet(isPresented: Bindable(model).showingSnapshots) {
            SnapshotsSheet().environment(model)
        }
        .sheet(isPresented: Bindable(model).showingSharedFolders) {
            SharedFoldersSheet().environment(model)
        }
        .onChange(of: model.settingsRequest) { openSettings() }
        .task {
            if model.vm?.state == .stopped { await model.bootVM() }
            await model.startDevelopmentTaskIfRequested()
            await model.continueRestoredTaskIfRequested()
        }
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
}
