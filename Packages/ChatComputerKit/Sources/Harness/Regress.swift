#if os(macOS)
import AppKit
import BridgeProtocol
import ChatCore
import Foundation
import GuestBridge
import HostControl
import ModelProxy
import Orchestrator
import VMKit

/// `cc-harness vm regress`: the fixed task set (scripts/regress/tasks.json) with the built-in agent on the real VM.
///
///     cc-harness vm regress [--model provider:protocol:model] [--runs N] [--only id,id] [--out results.jsonl] [--rebuild-base]
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
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--model": modelSpec = iterator.next() ?? modelSpec
            case "--runs": runs = iterator.next().flatMap(Int.init) ?? runs
            case "--only": only = iterator.next().map { Set($0.split(separator: ",").map(String.init)) }
            case "--out": output = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--rebuild-base": rebuildBase = true
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

        // Keep the user's state, and make the common starting point once.
        try await controller.takeSnapshot(name: beforeName, thumbnail: nil)
        try await waitReady(bridge, vmID: vmID, timeout: 120)
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
            try await clearFirstRunDialogs(controller)
            let base = try await controller.takeSnapshot(name: baseName, thumbnail: nil)
            try controller.setSnapshotProtected(base.id, true)
            VMProbe.log("took “\(baseName)”")
            try await waitReady(bridge, vmID: vmID, timeout: 120, screenOf: controller)
        }
        guard let base = controller.snapshots.first(where: { $0.name == baseName }) else { throw ProbeError("no base snapshot") }

        var results: [Result] = []
        for run in 1...runs {
            for spec in specs {
                try await controller.restoreSnapshot(base.id, savingCurrentAs: nil, thumbnail: nil)
                try await waitReady(bridge, vmID: vmID, timeout: 120)
                let result = await runTask(spec, run: run, agent: modelSpec, model: model, bridge: bridge, bundle: bundle, files: root.appendingPathComponent("files"))
                results.append(result)
                VMProbe.log("\(result.passed ? "PASS" : "FAIL") \(spec.id) #\(run) \(result.seconds)s turns=\(result.turns) in=\(result.inputTokens) cached=\(result.cachedInputTokens) out=\(result.outputTokens) — \(result.detail)")
                if let output, let line = try? JSONEncoder().encode(result) {
                    let handle = (try? FileHandle(forWritingTo: output)) ?? { FileManager.default.createFile(atPath: output.path, contents: nil); return try? FileHandle(forWritingTo: output) }()
                    try? handle?.seekToEnd()
                    try? handle?.write(contentsOf: line + Data([10]))
                    try? handle?.close()
                }
            }
        }

        summarize(results)
        if let before = controller.snapshots.first(where: { $0.name == beforeName }) {
            try await controller.restoreSnapshot(before.id, savingCurrentAs: nil, thumbnail: nil)
            try? controller.deleteSnapshot(before.id)
        }
        // Leave the VM suspended, so the app resumes exactly where the user was.
        try await waitReady(bridge, vmID: vmID, timeout: 120)
        try await controller.suspend()
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
    }

    static func runTask(_ spec: Spec, run: Int, agent: String, model: any ModelClient, bridge: BridgeServer,
                        bundle: VMBundle, files: URL) async -> Result {
        let folders = SharedFolders(root: bundle.sharedRoot)
        let runner = AgentRunner(goal: spec.goal, attachments: (spec.attachments ?? []).map { files.appendingPathComponent($0) },
                                 dependencies: .init(model: model, guest: bridge, store: InMemoryTaskStore(), lease: ControlLease(), folders: folders))
        let notes = NoteLog()
        let collector = Task {
            for await update in runner.updates {
                switch update {
                case .assistantNote(let text): await notes.add(text)
                case .needsUser: await notes.markAsked()
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
        }
        let text = await notes.text
        var failures: [String] = []
        for check in spec.checks {
            switch check.type {
            case "answer":
                let haystack = normalize(text)
                for needle in check.contains ?? [] where !haystack.contains(normalize(needle)) { failures.append("answer lacks “\(needle)”") }
            case "file":
                let url = folders.outbox(for: task).appendingPathComponent(check.name ?? "")
                guard let data = try? Data(contentsOf: url) else { failures.append("no \(check.name ?? "") in the outbox"); continue }
                // Case-insensitive: macOS capitalizes the first word of a line as it is typed.
                let content = String(decoding: data, as: UTF8.self).lowercased()
                for needle in check.contains ?? [] where !content.contains(needle.lowercased()) { failures.append("\(check.name ?? "") lacks “\(needle)”") }
            case "asksUser":
                if !(await notes.asked) { failures.append("did not ask before acting") }
                if task.phase == .completed { failures.append("finished without approval") }
            default:
                failures.append("unknown check \(check.type)")
            }
        }
        if !expectsQuestion, task.phase != .completed, failures.isEmpty { failures.append("ended \(task.phase)") }
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
        func add(_ note: String) { notes.append(note) }
        func markAsked() { asked = true }
        var text: String { notes.joined(separator: "\n") }
    }
}
#endif
