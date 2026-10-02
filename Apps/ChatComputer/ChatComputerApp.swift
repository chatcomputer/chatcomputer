import ChatCore
import SwiftUI

@main
struct ChatComputerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Chat Computer") {
            RootView()
                .environment(model)
        }
        // Sized for a landscape guest screen plus the side panel; onboarding and the main view share it.
        .defaultSize(WorkspaceMetrics.defaultContentSize)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Agent") {
                // Emergency stop is handled by the host, independent of guest or model (proposal §04).
                // The input shield holds focus while the agent runs, so the VM view can't swallow it.
                Button("Pause Agent") { model.pause() }
                    .keyboardShortcut(".", modifiers: .command)
                Button("Take Over") { model.takeOver() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Cancel Task") { model.cancel() }
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Model") {
                ModelSettingsForm()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}
