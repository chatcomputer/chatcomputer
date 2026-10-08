import AppKit
import BridgeProtocol
import ChatCore
import ModelProxy
import SwiftUI
import VMKit

/// The panes of the Settings window, listed in its sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case model, codingAgents, virtualMac, privacy, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .model: "Model"
        case .codingAgents: "Coding Agents"
        case .virtualMac: "Virtual Mac"
        case .privacy: "Privacy & Data"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .model: "sparkles"
        case .codingAgents: "terminal"
        case .virtualMac: "desktopcomputer"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .model: .purple
        case .codingAgents: Color(white: 0.35)
        case .virtualMac: .blue
        case .privacy: .indigo
        case .about: .gray
        }
    }
}

/// Settings: a sidebar of panes on the left, a grouped form on the right.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let pane = model.settingsPane ?? .model
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: $model.settingsPane) { pane in
                Label { Text(pane.title) } icon: {
                    // A white symbol on a coloured tile, as in System Settings and Xcode.
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(pane.tint.gradient, in: .rect(cornerRadius: 6))
                }
                .padding(.vertical, 2)
                .tag(pane)
            }
            .listStyle(.sidebar)
            .frame(width: 220)
            Divider()
            Group {
                switch pane {
                case .model: ModelSettingsForm(showsSavedKeys: true)
                case .codingAgents: CodingAgentsSettings()
                case .virtualMac: VirtualMacSettings()
                case .privacy: PrivacySettings()
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(pane.title)
        .frame(width: 820, height: 580)
    }
}

// MARK: Virtual Mac

struct VirtualMacSettings: View {
    @Environment(AppModel.self) private var model
    @State private var agentVersion: String?

    var body: some View {
        Form {
            if let vm = model.vm {
                let spec = vm.spec
                Section {
                    LabeledContent("Status", value: stateText(vm.state))
                    if let problem = model.guestReadiness?.problem {
                        LabeledContent("Not ready") { Text(problem).foregroundStyle(.orange) }
                    }
                    LabeledContent("macOS", value: spec.release.title + (spec.restoreImageBuild.map { " (\($0))" } ?? ""))
                    LabeledContent("Agent in the virtual Mac", value: agentVersion ?? "Not connected")
                    LabeledContent("Agent in this app", value: AppModel.bundledAgentVersion ?? "Missing")
                } header: {
                    Text("Status")
                } footer: {
                    Text("The app replaces an older agent in the virtual Mac by itself whenever the virtual Mac is idle.")
                }
                Section("Hardware") {
                    LabeledContent("Processors", value: "\(spec.cpuCount) cores")
                    LabeledContent("Memory", value: "\(spec.memoryBytes >> 30) GB")
                    LabeledContent("Disk", value: "\(spec.diskBytes >> 30) GB, grows as it fills")
                    LabeledContent("Display", value: "\(spec.displayWidth / 2) × \(spec.displayHeight / 2) points, Retina")
                }
                Section("Snapshots and Folders") {
                    LabeledContent("Snapshots") {
                        HStack {
                            Text("\(vm.snapshots.count)")
                            Button("Manage…") { model.showingSnapshots = true }
                        }
                    }
                    LabeledContent("Shared folders") {
                        HStack {
                            Text(vm.shares.isEmpty ? "Inbox and outbox only" : "\(vm.shares.count) of yours")
                            Button("Manage…") { model.showingSharedFolders = true }
                        }
                    }
                    LabeledContent("Stored at") {
                        HStack {
                            Text(abbreviated(vm.bundle.url.path)).truncationMode(.middle).lineLimit(1)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vm.bundle.url]) }
                        }
                    }
                }
            } else {
                Section {
                    Text("The virtual Mac is not set up yet. Finish the setup in the main window.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshAgentVersion() }
    }

    private func stateText(_ state: VirtualMachineController.State) -> String {
        switch state {
        case .running: "Running"
        case .starting: "Starting"
        case .stopped: "Off"
        case .paused: "Paused"
        case .saving: "Saving"
        case .error(let message): "Error: \(message)"
        }
    }

    private func refreshAgentVersion() async {
        guard let vm = model.vm, vm.state == .running, let bridge = model.bridge, await bridge.isConnected,
              case .health(let report)? = try? await bridge.send(.init(vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                                       deadline: Date().addingTimeInterval(5), command: .health))
        else { return }
        agentVersion = report.agentVersion
    }
}

// MARK: Privacy & Data

struct PrivacySettings: View {
    @Environment(AppModel.self) private var model

    private var support: URL { VMBundle.defaultLocation.deletingLastPathComponent() }

    var body: some View {
        Form {
            Section {
                LabeledContent("Screenshots of the virtual Mac", value: "Sent to your model provider")
                LabeledContent("Your tasks and replies", value: "Sent to your model provider")
                LabeledContent("API keys", value: "Only to their own provider")
                LabeledContent("The virtual Mac's password", value: "Never leaves this Mac")
            } header: {
                Text("What leaves this Mac")
            } footer: {
                Text("Chat Computer has no account, analytics or telemetry.")
            }
            Section("Stored on this Mac") {
                location("API keys", support.appendingPathComponent("credentials.json"), note: "Readable only by your account")
                location("Tasks and chats", support.appendingPathComponent("Tasks"), note: nil)
                location("Virtual Mac", VMBundle.defaultLocation, note: "Includes its password, readable only by your account")
            }
            Section {
                LabeledContent("Diagnostics") {
                    Button("Export Diagnostics…") { Task { await Diagnostics.export(model) } }
                }
            } footer: {
                Text("Saves a zip to your Desktop for a bug report: versions, the virtual Mac's state, recent tasks and the app's log. API keys and passwords are removed; the task logs contain your chat with the agent.")
            }
            Section {
                Link("Read the privacy notice", destination: URL(string: "https://github.com/chatcomputer/chatcomputer/blob/main/PRIVACY.md")!)
            }
        }
        .formStyle(.grouped)
    }

    private func location(_ title: String, _ url: URL, note: String?) -> some View {
        LabeledContent {
            Button("Show in Finder") {
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
            }
        } label: {
            Text(title)
            Text(note.map { "\(abbreviated(url.path)) · \($0)" } ?? abbreviated(url.path))
        }
    }
}

// MARK: About

struct AboutSettings: View {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chat Computer").font(.title2.weight(.semibold))
                        Text("Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
                            .foregroundStyle(.secondary)
                        Text("A second Mac that does the work while you chat.").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Links") {
                link("Website", "chatcomputer.github.io", "https://chatcomputer.github.io")
                link("Release notes", "Releases on GitHub", "https://github.com/chatcomputer/chatcomputer/releases")
                link("Source code", "chatcomputer/chatcomputer", "https://github.com/chatcomputer/chatcomputer")
                link("Report a problem", "Open an issue", "https://github.com/chatcomputer/chatcomputer/issues/new/choose")
            }
            Section {
                LabeledContent("License", value: "Apache 2.0")
            } footer: {
                Text("Not affiliated with Apple. macOS is a trademark of Apple Inc. Apple's licence limits what macOS virtual machines may be used for: development, testing and personal non-commercial use.")
            }
        }
        .formStyle(.grouped)
    }

    private func link(_ title: String, _ text: String, _ url: String) -> some View {
        LabeledContent(title) { Link(text, destination: URL(string: url)!) }
    }
}

/// `~` for the home folder, as Finder shows paths.
func abbreviated(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}
