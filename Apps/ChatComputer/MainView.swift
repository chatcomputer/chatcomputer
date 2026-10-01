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

/// Two panes: guest desktop on the left (~2/3), host chat on the right.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            VMDisplayView(virtualMachine: model.vm?.virtualMachine, agentHoldsInput: model.agentHoldsInput,
                          onUserIntervention: { model.takeOver() })
                .frame(minWidth: 640, idealWidth: 960)
            ChatPanel()
                .frame(minWidth: 320, idealWidth: 420)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Label(statusText, systemImage: "desktopcomputer").labelStyle(.titleAndIcon)
            }
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
        return "\(model.vm?.spec.name ?? "Chat Computer") · \(vmState) · \(holder)"
    }
}
