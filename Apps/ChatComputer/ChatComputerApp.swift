import AppKit
import ChatCore
import ComputerControl
import Foundation
import SwiftUI

/// One executable, two faces: `chatcomputer <command>` (or the app binary with a command) is the
/// command line tool coding agents use; anything else opens the app.
@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if ControlCommandLine.isCommandLine(arguments) {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            Task { exit(await ControlCommandLine.run(arguments, version: version)) }
            dispatchMain()
        }
        // One copy at a time: a second one (another build, or a second launch from a different path)
        // brings the running copy forward and quits, so it never competes for the virtual Mac or the socket.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let running = others.first {
            running.activate()
            exit(0)
        }
        ChatComputerApp.main()
    }
}

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
            CommandGroup(before: .toolbar) {
                Button(model.isPanelCollapsed ? "Show Chat" : "Hide Chat") { model.setPanelCollapsed(!model.isPanelCollapsed) }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                    .disabled(!model.isReady)
                Divider()
            }
            CommandMenu("Machine") {
                Button("Take Snapshot") { Task { await model.takeSnapshot() } }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(!model.canManageSnapshots)
                Button("Snapshots…") { model.showingSnapshots = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.isReady)
                Button("Shared Folders…") { model.showingSharedFolders = true }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!model.isReady)
            }
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
            Section("Coding agents") {
                CodingAgentsSettings()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}
