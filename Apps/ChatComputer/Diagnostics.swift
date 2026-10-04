import AppKit
import BridgeProtocol
import ChatCore
import Foundation
import VMKit

/// Help › Export Diagnostics: a zip on the Desktop for a bug report. It holds versions, the virtual Mac's
/// configuration and state, the agent's health, the last few tasks and the app's recent log. It never includes the
/// secret files, and every text goes through `Redactor`, which removes the stored secrets wherever they appear.
@MainActor
enum Diagnostics {
    static let taskCount = 5

    static func export(_ model: AppModel) async {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let name = "Chat Computer Diagnostics \(stamp)"
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let archive = desktop.appendingPathComponent(name + ".zip")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let redactor = Redactor(secrets: storedSecrets(model))
            func write(_ text: String, _ file: String) throws {
                let url = staging.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(redactor.redact(text).utf8).write(to: url)
            }
            try write(await summary(model), "summary.txt")
            for task in recentTasks(model) {
                for file in ["task.json", "events.jsonl"] {
                    if let text = try? String(contentsOf: task.appendingPathComponent(file), encoding: .utf8) {
                        try write(text, "tasks/\(task.lastPathComponent)/\(file)")
                    }
                }
            }
            try write(await appLog(), "app-log.txt")
            try? FileManager.default.removeItem(at: archive)
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            zip.arguments = ["-c", "-k", "--keepParent", staging.path, archive.path]
            try zip.run()
            zip.waitUntilExit()
            try? FileManager.default.removeItem(at: staging.deletingLastPathComponent())
            guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
            NSWorkspace.shared.activateFileViewerSelecting([archive])
            model.transcript.append(ChatItem(role: .system, text: "Saved diagnostics to the Desktop: \(archive.lastPathComponent). It contains no API keys or passwords; the task logs include your chat with the agent."))
        } catch {
            model.errorMessage = "Could not export diagnostics: \(error.localizedDescription)"
        }
    }

    /// Every stored secret value, read only to be removed from the archive.
    private static func storedSecrets(_ model: AppModel) -> [String] {
        let files = [model.bundle.secretStore().url,
                     VMBundle.defaultLocation.deletingLastPathComponent().appendingPathComponent("credentials.json")]
        return files.flatMap { url -> [String] in
            guard let data = try? Data(contentsOf: url),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return values.values.compactMap { $0 as? String }
        }
    }

    private static func summary(_ model: AppModel) async -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let process = ProcessInfo.processInfo
        var lines = [
            "Chat Computer \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "Bundled agent: \(AppModel.bundledAgentVersion ?? "missing")",
            "Host: macOS \(process.operatingSystemVersionString), \(hardwareModel()), \(process.processorCount) cores, \(process.physicalMemory >> 30) GB",
            "Free disk: \(SnapshotStore.availableCapacity(for: model.bundle.url) >> 30) GB",
            "Model: \(model.modelSettings.providerID) · \(model.modelSettings.protocolKind) · \(model.modelSettings.model) · \(model.modelSettings.baseURL)",
            "Task phase: \(model.phase)",
        ]
        guard let vm = model.vm else { return (lines + ["Virtual Mac: not set up"]).joined(separator: "\n") + "\n" }
        let spec = vm.spec
        lines += [
            "",
            "Virtual Mac: \(vm.state), stage \(spec.stage.rawValue), macOS build \(spec.restoreImageBuild ?? "?")",
            "  \(spec.cpuCount) CPUs, \(spec.memoryBytes >> 30) GB memory, \(spec.diskBytes >> 30) GB disk, \(spec.displayWidth)×\(spec.displayHeight), \(spec.overlayCount) overlay(s)",
            "  Readiness: \(model.guestReadiness.map { $0.problem ?? "ready" } ?? "unknown")",
        ]
        if vm.state == .running, let bridge = model.bridge, await bridge.isConnected,
           case .health(let report)? = try? await bridge.send(.init(vmID: spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                                    deadline: Date().addingTimeInterval(5), command: .health)) {
            lines.append("  Agent: \(report.agentVersion), driver \(report.driver), desktop \(report.hasAquaSession ? "yes" : "no"), locked \(report.screenLocked), accessibility \(report.accessibilityGranted), screen recording \(report.screenRecordingGranted), shared folders \(report.sharedFoldersMounted)")
        } else {
            lines.append("  Agent: not connected")
        }
        lines.append("")
        lines.append("Snapshots (\(vm.snapshots.count)):")
        for snapshot in vm.snapshots {
            lines.append("  \(snapshot.name) · \(snapshot.kind.rawValue) · \(snapshot.createdAt)\(snapshot.id == vm.currentSnapshotID ? " · current" : "")")
        }
        lines.append("Shared folders: \(vm.shares.count)")
        for share in vm.shares {
            // Paths can name people or clients: keep only the folder name.
            lines.append("  \(share.name) · \(share.readOnly ? "read-only" : "read & write") · \(share.exists ? "present" : "missing")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func recentTasks(_ model: AppModel) -> [URL] {
        let root = VMBundle.defaultLocation.deletingLastPathComponent().appendingPathComponent("Tasks", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return folders
            .sorted { modified($0) > modified($1) }
            .prefix(taskCount)
            .map { $0 }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The app's own messages from the unified log, last 30 minutes. `log show` can take minutes on a busy
    /// system, so it is cut off after a minute.
    private static func appLog() async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["show", "--last", "30m", "--style", "compact", "--predicate", "process == \"ChatComputer\""]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "log unavailable" }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            deadline.cancel()
            process.waitUntilExit()
            // Keep the end: the most recent part matters, and the archive stays small.
            let text = String(decoding: data.suffix(4_000_000), as: UTF8.self)
            return text.isEmpty ? "no log entries" : text
        }.value
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
