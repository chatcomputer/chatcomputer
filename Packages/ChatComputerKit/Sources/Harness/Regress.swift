#if os(macOS)
import AppKit
import BridgeProtocol
import ChatCore
import Foundation
import GuestBridge
import HostControl
import ImageIO
import ModelProxy
import Orchestrator
import Virtualization
import VMKit

/// `cc-harness vm regress`: the fixed task set (scripts/regress/tasks.json) with the built-in agent on the real VM.
///
///     cc-harness vm regress [--model provider:protocol:model] [--runs N] [--only id,id] [--out results.jsonl] [--rebuild-base [--agent ChatComputerAgent.app]]
///
/// Every task starts from the snapshot "Regression base" (made once from "Freshly set up"). The VM's state
/// before the run is saved as "Before regression" and restored at the end. The API key comes from
/// $CC_API_KEY or the app's credentials.json. Prints one line per task and a summary table.
@MainActor
enum Regress {
    struct Suite: Decodable { let tasks: [Spec] }
    struct Spec: Decodable {
        let id: String
        let goal: String
        let attachments: [String]?
        let checks: [Check]
    }
    struct Check: Decodable {
        let type: String
        let name: String?
        let contains: [String]?
        let absent: [String]?
    }
    struct Result: Encodable {
        let task: String
        let run: Int
        let agent: String
        let passed: Bool
        let detail: String
        let seconds: Int
        let turns: Int
        let actions: Int
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
    }

    static let baseName = "Regression base"
    static let beforeName = "Before regression"

    static func run(arguments: [String]) async throws {
        var modelSpec = ProcessInfo.processInfo.environment["CC_REGRESS_MODEL"] ?? "deepseek:openAI:deepseek-flash"
        var runs = 1
        var only: Set<String>?
        var output: URL?
        var rebuildBase = false
        var agent: URL?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--model": modelSpec = iterator.next() ?? modelSpec
            case "--runs": runs = iterator.next().flatMap(Int.init) ?? runs
            case "--only": only = iterator.next().map { Set($0.split(separator: ",").map(String.init)) }
            case "--out": output = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--rebuild-base": rebuildBase = true
            case "--agent": agent = iterator.next().map { URL(fileURLWithPath: $0) }
            default: throw ProbeError("unknown option \(argument)")
            }
        }

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../scripts/regress").standardizedFileURL
        let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf: root.appendingPathComponent("tasks.json")))
        let specs = suite.tasks.filter { only?.contains($0.id) ?? true }

        let settings = try modelSettings(modelSpec)
        let stored = try FileSecretStore(url: VMBundle.defaultLocation.deletingLastPathComponent().appendingPathComponent("credentials.json"))
            .read(settings.secretAccount)
        let key = ProcessInfo.processInfo.environment["CC_API_KEY"] ?? stored
        guard let key, !key.isEmpty else { throw ProbeError("no API key: set CC_API_KEY or store one in the app first") }
        let model = try settings.makeClient { key }

        let bundle = VMProbe.bundle
        let controller = try VirtualMachineController(bundle: bundle)
        let vmID = controller.spec.id
        guard let token = try bundle.secretStore().read(SecretAccount.pairingToken(vmID: vmID)) else { throw ProbeError("no pairing token") }
        let bridge = BridgeServer(vmID: vmID, pairingToken: token)
        controller.onSocketDeviceReady = { bridge.attach(to: $0) }
        await controller.start()
        try await waitReady(bridge, vmID: vmID, timeout: 180)

        // Keep the user's state, and make the common starting point once. An interrupted earlier run left its
        // "Before regression" behind, and the machine now holds that run's leftovers: keep the oldest one.
        let earlier = controller.snapshots.filter { $0.name == beforeName }.sorted { $0.createdAt < $1.createdAt }
        if earlier.isEmpty {
            try await controller.takeSnapshot(name: beforeName, thumbnail: nil)
            try await waitReady(bridge, vmID: vmID, timeout: 120)
        } else {
            for duplicate in earlier.dropFirst() { try controller.deleteSnapshot(duplicate.id) }
            VMProbe.log("reusing “\(beforeName)” from \(earlier[0].createdAt) (an earlier run was interrupted)")
        }
        let watcher = ConsentWatcher(controller: controller)
        if rebuildBase, let old = controller.snapshots.first(where: { $0.name == baseName }) {
            try controller.setSnapshotProtected(old.id, false)
            try controller.deleteSnapshot(old.id)
        }
        if !controller.snapshots.contains(where: { $0.name == baseName }) {
            guard let initial = controller.snapshots.first(where: { $0.kind == .initial }) else { throw ProbeError("no initial snapshot") }
            VMProbe.log("making “\(baseName)” from “\(initial.name)”…")
            try await controller.restoreSnapshot(initial.id, savingCurrentAs: nil, thumbnail: nil)
            try await waitReady(bridge, vmID: vmID, timeout: 300, screenOf: controller)
            VMProbe.log("cold boot from “\(initial.name)” ready")
            try await Task.sleep(for: .seconds(15))   // let login items settle
            // A screenshot through the agent makes macOS show its screen recording prompt now, so it is answered
            // before the snapshot instead of greeting every task.
            _ = try? await bridge.send(CommandEnvelope(vmID: vmID, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                       deadline: Date().addingTimeInterval(10), command: .screenshot(region: nil)))
            try await clearFirstRunDialogs(controller)
            if let agent {
                try await installAgent(agent, controller: controller, bridge: bridge, vmID: vmID)
                try await clearFirstRunDialogs(controller)   // the new agent may ask about screen recording again
            }
            let base = try await controller.takeSnapshot(name: baseName, thumbnail: nil)
            try controller.setSnapshotProtected(base.id, true)
            VMProbe.log("took “\(baseName)”")
            try await waitReady(bridge, vmID: vmID, timeout: 120, screenOf: controller)
        }
        guard let base = controller.snapshots.first(where: { $0.name == baseName }) else { throw ProbeError("no base snapshot") }

        var results: [Result] = []
        runs: for run in 1...runs {
            for spec in specs {
                watcher.detach()
                try await controller.restoreSnapshot(base.id, savingCurrentAs: nil, thumbnail: nil)
                try await waitReady(bridge, vmID: vmID, timeout: 120)
                watcher.attach()
                let result = await runTask(spec, run: run, agent: modelSpec, model: model, bridge: bridge, bundle: bundle, files: root.appendingPathComponent("files"))
                results.append(result)
                VMProbe.log("\(result.passed ? "PASS" : "FAIL") \(spec.id) #\(run) \(result.seconds)s turns=\(result.turns) in=\(result.inputTokens) cached=\(result.cachedInputTokens) out=\(result.outputTokens) — \(result.detail)")
                if let output, let line = try? JSONEncoder().encode(result) {
                    let handle = (try? FileHandle(forWritingTo: output)) ?? { FileManager.default.createFile(atPath: output.path, contents: nil); return try? FileHandle(forWritingTo: output) }()
                    try? handle?.seekToEnd()
                    try? handle?.write(contentsOf: line + Data([10]))
                    try? handle?.close()
                }
                // An empty model account fails every later task the same way: stop and say so.
                if result.detail.hasPrefix("model account out of credit") {
                    VMProbe.log("stopping: the model provider account is out of credit")
                    break runs
                }
            }
        }

        summarize(results)
        watcher.detach()
        if let before = controller.snapshots.filter({ $0.name == beforeName }).min(by: { $0.createdAt < $1.createdAt }) {
            try await controller.restoreSnapshot(before.id, savingCurrentAs: nil, thumbnail: nil)
            try? controller.deleteSnapshot(before.id)
        }
        // Leave the VM suspended, so the app resumes exactly where the user was.
        try await waitReady(bridge, vmID: vmID, timeout: 120)
        try await controller.suspend()
    }

    /// Puts `agent` (a ChatComputerAgent.app signed like the installed one) into the guest before the base is taken,
    /// as the app does: the agent replaces itself from the bootstrap share. An agent from before 0.1.0 cannot do
    /// that safely, so if it is still the old version afterwards, the copy is made from the guest's Terminal,
    /// typed from the host.
    static func installAgent(_ agent: URL, controller: VirtualMachineController, bridge: BridgeServer, vmID: UUID) async throws {
        guard let expected = AgentVersion.of(bundle: agent) else { throw ProbeError("\(agent.path) is not an agent bundle") }
        func health() async -> HealthReport? {
            guard await bridge.isConnected,
                  case .health(let report)? = try? await bridge.send(CommandEnvelope(vmID: vmID, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                                                       deadline: Date().addingTimeInterval(5), command: .health)) else { return nil }
            return report
        }
        func waitForVersion(_ seconds: Int) async -> Bool {
            for _ in 0..<seconds {
                if await health()?.agentVersion == expected { return true }
                try? await Task.sleep(for: .seconds(1))
            }
            return false
        }
        let running = await health()?.agentVersion ?? "unknown"
        guard running != expected else { VMProbe.log("agent is already \(expected)"); return }

        let staged = try AgentStaging.stage(agent, in: controller.bundle.bootstrapDirectory)
        defer { try? FileManager.default.removeItem(at: staged) }
        try await Task.sleep(for: .seconds(3))
        _ = try? await bridge.send(CommandEnvelope(vmID: vmID, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                   deadline: Date().addingTimeInterval(30), command: .updateAgent))
        try await Task.sleep(for: .seconds(3))
        if await waitForVersion(60) { VMProbe.log("agent updated \(running) → \(expected)"); return }

        VMProbe.log("agent \(running) did not update itself; installing from the guest's Terminal")
        guard let machine = controller.virtualMachine else { throw ProbeError("no machine") }
        let (view, window) = VMProbe.showWindow(machine, spec: controller.spec)
        defer {
            view.virtualMachine = nil
            window.close()
        }
        let display = HostDisplay(view: view, guestSize: CGSize(width: controller.spec.displayWidth / 2, height: controller.spec.displayHeight / 2))
        try await Task.sleep(for: .seconds(2))
        try await display.key("cmd+space")
        try await Task.sleep(for: .seconds(1.5))
        try await display.type("Terminal")
        try await Task.sleep(for: .seconds(1.5))
        try await display.key("return")
        try await Task.sleep(for: .seconds(4))
        // Another window can keep the focus; click into Terminal's window first.
        if let image = display.capture(), let screen = try? ScreenText.recognize(image, guestSize: display.guestSize),
           let prompt = screen.first("Last login") ?? screen.first("agent@") {
            display.click(prompt.center)
            try await Task.sleep(for: .seconds(0.5))
        }
        try await display.type(#"ditto "/Volumes/My Shared Files/bootstrap/$(cat "/Volumes/My Shared Files/bootstrap/next-agent")" ~/Applications/.cc-new.app && rm -rf /tmp/cc-old.app && mv ~/Applications/ChatComputerAgent.app /tmp/cc-old.app && mv ~/Applications/.cc-new.app ~/Applications/ChatComputerAgent.app && launchctl kickstart -k gui/$(id -u)/app.chatcomputer.agent; exit"#)
        try await display.key("return")
        let updated = await waitForVersion(60)
        if !updated, let image = display.capture(),
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            let url = controller.bundle.url.appendingPathComponent("regress-agent-install.png")
            try? data.write(to: url)
            VMProbe.log("guest screen → \(url.path)")
        }
        try await display.key("cmd+q")   // Terminal
        try await Task.sleep(for: .seconds(1.5))
        guard updated else { throw ProbeError("the agent is still \(await health()?.agentVersion ?? "unknown"), not \(expected)") }
        VMProbe.log("agent installed \(running) → \(expected)")
    }

    /// A freshly booted guest shows prompts that every task would otherwise start by dismissing: macOS asking
    /// again about the agent's screen recording, and Spotlight's welcome. Answered from the host, as the app does.
    static func clearFirstRunDialogs(_ controller: VirtualMachineController) async throws {
        guard let machine = controller.virtualMachine else { return }
        let (view, window) = VMProbe.showWindow(machine, spec: controller.spec)
        // A second view left attached to the machine breaks saving and restoring its state (the restored guest
        // stays black): detach it before the snapshot is taken.
        defer {
            view.virtualMachine = nil
            window.close()
        }
        let display = HostDisplay(view: view, guestSize: CGSize(width: controller.spec.displayWidth / 2, height: controller.spec.displayHeight / 2))
        for _ in 0..<6 {
            try await Task.sleep(for: .seconds(2))
            if await ConsentPrompt.approveIfShown(on: display) { VMProbe.log("answered the screen recording prompt"); continue }
            guard let image = display.capture(),
                  let screen = try? ScreenText.recognize(image, guestSize: display.guestSize) else { continue }
            if screen.contains("Spotlight"), let button = screen.first("Continue") {
                display.click(button.center)
                VMProbe.log("dismissed Spotlight's welcome")
                continue
            }
            break
        }
        // System Settings is left open by onboarding's permission step; Spotlight shows a welcome panel the first
        // time it opens. Both would cost every task a few turns.
        // Its sidebar gives it away even when another app is in front: click it to bring it forward, then quit it.
        if let image = display.capture(), let screen = try? ScreenText.recognize(image, guestSize: display.guestSize),
           let sidebar = screen.first("Bluetooth"), screen.contains("Wi-Fi") {
            display.click(sidebar.center)
            try await Task.sleep(for: .seconds(1))
            try await display.key("cmd+q")
            VMProbe.log("quit System Settings")
            try await Task.sleep(for: .seconds(2))
        }
        try await display.key("cmd+space")
        try await Task.sleep(for: .seconds(2.5))
        if let image = display.capture(), let screen = try? ScreenText.recognize(image, guestSize: display.guestSize),
           let button = screen.first("Continue") {
            display.click(button.center)
            VMProbe.log("dismissed Spotlight's welcome")
            try await Task.sleep(for: .seconds(1.5))
        }
        try await display.key("escape")
        try await Task.sleep(for: .seconds(1))
    }

    /// The app's answer to macOS's periodic screen-recording prompt (`ConsentPrompt`), for unattended runs.
    /// It needs a view of the machine; that view is detached around every snapshot operation, because a
    /// second view left attached while the machine's state is saved leaves the restored guest black.
    @MainActor
    final class ConsentWatcher {
        let controller: VirtualMachineController
        private var view: VZVirtualMachineView?
        private var window: NSWindow?
        private var task: Task<Void, Never>?

        init(controller: VirtualMachineController) { self.controller = controller }

        func attach() {
            guard let machine = controller.virtualMachine else { return }
            if view == nil {
                let shown = VMProbe.showWindow(machine, spec: controller.spec)
                view = shown.0
                window = shown.1
            }
            view?.virtualMachine = machine
            let size = CGSize(width: controller.spec.displayWidth / 2, height: controller.spec.displayHeight / 2)
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard let self, let view = self.view, view.virtualMachine != nil else { continue }
                    if await ConsentPrompt.approveIfShown(on: HostDisplay(view: view, guestSize: size)) {
                        VMProbe.log("answered the screen recording prompt")
                    }
                }
            }
        }

        func detach() {
            task?.cancel()
            task = nil
            view?.virtualMachine = nil
        }
    }

    static func runTask(_ spec: Spec, run: Int, agent: String, model: any ModelClient, bridge: BridgeServer,
                        bundle: VMBundle, files: URL) async -> Result {
        let folders = SharedFolders(root: bundle.sharedRoot)
        var dependencies = AgentRunner.Dependencies(model: model, guest: bridge, store: InMemoryTaskStore(), lease: ControlLease(), folders: folders)
        dependencies.locateText = { data, text in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return await ScreenText.locate(text, inImage: data, width: image.width, height: image.height)
        }
        let runner = AgentRunner(goal: spec.goal, attachments: (spec.attachments ?? []).map { files.appendingPathComponent($0) },
                                 dependencies: dependencies)
        let notes = NoteLog()
        let collector = Task {
            for await update in runner.updates {
                switch update {
                case .assistantNote(let text): await notes.add(text)
                case .action(let name): await notes.addAction(name)
                case .needsUser: await notes.markAsked()
                case .notice(let text): await notes.add("notice: \(text)")
                default: break
                }
            }
        }
        let started = Date()
        let expectsQuestion = spec.checks.contains { $0.type == "asksUser" }
        // Ten minutes per task; cancelling ends the loop.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(600))
            await runner.cancel()
        }
        do { try await runner.start() } catch { await notes.add("start failed: \(error)") }
        var answers = 0
        while case .waitingForUser = await runner.task.phase {
            if expectsQuestion || answers >= 2 { await runner.cancel(); break }
            answers += 1
            await runner.answer("Please go ahead without asking me; make reasonable choices.")
        }
        watchdog.cancel()
        collector.cancel()

        let task = await runner.task
        let usage = await runner.checkpoint().usage
        // The final screen, for looking into failures and for documentation.
        if let shots = ProcessInfo.processInfo.environment["CC_REGRESS_SHOTS"],
           case .screenshot(let shot)? = try? await bridge.send(CommandEnvelope(vmID: bridge.vmID, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                                               deadline: Date().addingTimeInterval(10), command: .screenshot(region: nil))) {
            try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
            try? shot.imageData.write(to: URL(fileURLWithPath: shots).appendingPathComponent("\(spec.id)-\(run).png"))
            try? Data(await notes.log.utf8).write(to: URL(fileURLWithPath: shots).appendingPathComponent("\(spec.id)-\(run).log"))
        }
        let text = await notes.text
        var failures: [String] = []
        for check in spec.checks {
            switch check.type {
            case "answer":
                let haystack = normalize(text)
                for needle in check.contains ?? [] where !haystack.contains(normalize(needle)) { failures.append("answer lacks “\(needle)”") }
            case "answerAny":
                let haystack = normalize(text)
                if !(check.contains ?? []).contains(where: { haystack.contains(normalize($0)) }) {
                    failures.append("answer mentions none of \((check.contains ?? []).joined(separator: ", "))")
                }
            case "file":
                let url = folders.outbox(for: task).appendingPathComponent(check.name ?? "")
                guard let data = try? Data(contentsOf: url) else { failures.append("no \(check.name ?? "") in the outbox"); continue }
                // Case-insensitive: macOS capitalizes the first word of a line as it is typed.
                let content = String(decoding: data, as: UTF8.self).lowercased()
                for needle in check.contains ?? [] where !content.contains(needle.lowercased()) { failures.append("\(check.name ?? "") lacks “\(needle)”") }
                for needle in check.absent ?? [] where content.contains(needle.lowercased()) { failures.append("\(check.name ?? "") still has “\(needle)”") }
            case "asksUser":
                if !(await notes.asked) { failures.append("did not ask before acting") }
                if task.phase == .completed { failures.append("finished without approval") }
            default:
                failures.append("unknown check \(check.type)")
            }
        }
        if !expectsQuestion, task.phase != .completed, failures.isEmpty { failures.append("ended \(task.phase)") }
        if await notes.notes.contains(where: { $0.contains("out of credit") }) { failures.insert("model account out of credit", at: 0) }
        let detail = failures.isEmpty ? "ok" : failures.joined(separator: "; ")
        return Result(task: spec.id, run: run, agent: agent, passed: failures.isEmpty, detail: detail,
                      seconds: Int(Date().timeIntervalSince(started)), turns: usage.modelTurns, actions: usage.actions,
                      inputTokens: usage.inputTokens, cachedInputTokens: usage.cachedInputTokens, outputTokens: usage.outputTokens)
    }

    /// Lowercased, without thousands separators or spaces between digits.
    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "\u{202F}", with: "")
    }

    static func summarize(_ results: [Result]) {
        let passed = results.filter(\.passed).count
        VMProbe.log("passed \(passed)/\(results.count)")
        let seconds = results.map(\.seconds).reduce(0, +)
        let input = results.map(\.inputTokens).reduce(0, +)
        let cached = results.map(\.cachedInputTokens).reduce(0, +)
        let output = results.map(\.outputTokens).reduce(0, +)
        VMProbe.log("total \(seconds)s, input \(input) (\(input > 0 ? cached * 100 / input : 0)% cached), output \(output)")
    }

    static func modelSettings(_ spec: String) throws -> ModelSettings {
        let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let provider = ModelCatalog.provider(parts[0]), let kind = ModelProtocol(rawValue: parts[1]) else {
            throw ProbeError("--model must look like provider:protocol:model")
        }
        var settings = ModelSettings.preset(provider)
        settings.protocolKind = kind
        settings.baseURL = provider.endpoints[kind] ?? settings.baseURL
        settings.model = parts[2]
        return settings
    }

    static func waitReady(_ bridge: BridgeServer, vmID: UUID, timeout: TimeInterval,
                          screenOf controller: VirtualMachineController? = nil) async throws {
        let deadline = Date().addingTimeInterval(max(timeout, 300))
        var last = "agent not connected"
        while Date() < deadline {
            if await bridge.isConnected {
                if case .health(let report)? = try? await bridge.send(CommandEnvelope(vmID: vmID, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                                                     deadline: Date().addingTimeInterval(5), command: .health)) {
                    if report.isDesktopReady { return }
                    last = "\(report)"
                } else {
                    last = "agent connected but not answering"
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        // Show what the guest's screen looks like, from the host (no agent needed).
        if let controller, let machine = controller.virtualMachine {
            let (view, _) = VMProbe.showWindow(machine, spec: controller.spec)
            try? await Task.sleep(for: .seconds(2))
            if let image = HostDisplay(view: view, guestSize: CGSize(width: controller.spec.displayWidth / 2, height: controller.spec.displayHeight / 2)).capture(),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                let url = controller.bundle.url.appendingPathComponent("regress-not-ready.png")
                try? data.write(to: url)
                VMProbe.log("guest screen → \(url.path)")
            }
        }
        throw ProbeError("the guest did not become ready: \(last)")
    }

    private actor NoteLog {
        private(set) var notes: [String] = []
        private(set) var asked = false
        private var lines: [String] = []
        func add(_ note: String) { notes.append(note); lines.append("note: " + note) }
        func addAction(_ action: String) { lines.append("action: " + action) }
        var log: String { lines.joined(separator: "\n") }
        func markAsked() { asked = true }
        var text: String { notes.joined(separator: "\n") }
    }
}
#endif
