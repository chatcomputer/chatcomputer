import ChatCore
import SwiftUI

@main
struct ChatComputerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Chat Computer") {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
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
    @State private var apiKey = ""
    @State private var savedSuffix: String?

    var body: some View {
        Form {
            Section("Model") {
                LabeledContent("Model", value: "Claude Opus 5.5")
                if let savedSuffix { LabeledContent("Saved key", value: "…\(savedSuffix)") }
                SecureField("Anthropic API key", text: $apiKey)
                HStack {
                    Button("Save") {
                        try? model.secrets.write(apiKey, for: SecretAccount.anthropicAPIKey)
                        apiKey = ""
                        refresh()
                    }
                    .disabled(apiKey.isEmpty)
                    Button("Remove", role: .destructive) {
                        try? model.secrets.delete(SecretAccount.anthropicAPIKey)
                        refresh()
                    }
                }
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        savedSuffix = (try? model.secrets.read(SecretAccount.anthropicAPIKey))?.suffix(4).description
    }
}
