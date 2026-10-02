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

    var body: some View {
        Workspace {
            GuestStage(virtualMachine: model.vm?.virtualMachine, aspectRatio: model.guestAspectRatio,
                       agentHoldsInput: model.agentHoldsInput, onUserIntervention: { model.takeOver(reason: $0) },
                       onViewReady: { model.guestView = $0 }) {
                GuestPlaceholder(title: model.vm?.state == .starting ? "Starting your virtual Mac…" : "Your virtual Mac is off")
            }
        } panel: {
            ChatPanel()
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
                    EmptyView()
                }
                if !model.phase.isTerminal, model.phase != .ready {
                    Button("Cancel task", systemImage: "xmark") { model.cancel() }
                }
            }
        }
        .task {
            if model.vm?.state == .stopped { await model.bootVM() }
            await model.startDevelopmentTaskIfRequested()
        }
    }

    private var statusText: String {
        let vmState = switch model.vm?.state {
        case .running: "Running"
        case .starting: "Starting"
        case .paused: "Paused"
        case .saving: "Saving"
        case .error(let message): "Error: \(message)"
        case .stopped, nil: "Stopped"
        }
        let holder = model.agentHoldsInput ? "Agent has control" : "You have control"
        return "\(vmState) · \(holder)"
    }
}
