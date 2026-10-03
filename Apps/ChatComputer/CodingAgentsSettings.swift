import AppKit
import SwiftUI

/// Settings › Coding agents: how Claude Code, Codex and other agents outside the app reach the virtual Mac.
struct CodingAgentsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var installedAt = CommandLineTool.installedLink()
    @State private var installMessage: String?

    private var executable: String { Bundle.main.executablePath ?? "/Applications/ChatComputer.app/Contents/MacOS/ChatComputer" }
    private var command: String { installedAt == nil ? "\"\(executable)\"" : "chatcomputer" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Coding agents on this Mac can see and operate the virtual Mac with the `chatcomputer` command, or as an MCP server. They follow the same rules as the built-in agent: click the screen to take over at any time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let holder = model.externalHolder {
                Label("\(holder) is controlling the virtual Mac", systemImage: "terminal.fill").foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Command line tool").font(.headline)
                if let installedAt {
                    Label("Installed: \(installedAt)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    HStack {
                        Button("Install chatcomputer Command") { install() }
                        Text("Links it into a folder on your PATH.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let installMessage {
                    Text(installMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Snippet(title: "Tell your agent (add to CLAUDE.md or AGENTS.md)", text: """
                A macOS virtual machine is available through Chat Computer. To use a real Mac desktop (GUI apps, \
                browsers, UI tests), run `\(command) help` first, then use its commands: take a screenshot, act, \
                and take another screenshot to check. Release control when done.
                """)
            Snippet(title: "Claude Code (MCP)", text: "claude mcp add chatcomputer -- \(command) mcp")
            Snippet(title: "Codex (~/.codex/config.toml)", text: """
                [mcp_servers.chatcomputer]
                command = "\(installedAt ?? executable)"
                args = ["mcp"]
                """)
            Snippet(title: "Other MCP clients (JSON)", text: """
                "chatcomputer": { "command": "\(installedAt ?? executable)", "args": ["mcp"] }
                """)
        }
        .padding(.vertical, 4)
    }

    private func install() {
        switch CommandLineTool.install(executable: executable) {
        case .success(let path):
            installedAt = path
            installMessage = nil
        case .failure(let manual):
            installMessage = "No folder on your PATH is writable without an administrator password. Run this in Terminal:\n\(manual)"
        }
    }
}

private struct Snippet: View {
    let title: String
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .controlSize(.small)
            }
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 6))
        }
    }
}

/// The `chatcomputer` symlink to the app's executable.
enum CommandLineTool {
    /// Folders commonly on PATH, in order of preference. Homebrew's is user-writable on Apple silicon.
    static let folders = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]

    static func installedLink() -> String? {
        for folder in folders {
            let path = folder + "/chatcomputer"
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { return path }
        }
        return nil
    }

    enum Outcome {
        case success(String)
        /// A command to run with sudo.
        case failure(String)
    }

    static func install(executable: String) -> Outcome {
        for folder in folders.dropLast() where FileManager.default.isWritableFile(atPath: folder) {
            let path = folder + "/chatcomputer"
            try? FileManager.default.removeItem(atPath: path)
            if (try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: executable)) != nil { return .success(path) }
        }
        return .failure("sudo ln -sf \"\(executable)\" /usr/local/bin/chatcomputer")
    }
}
