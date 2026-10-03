import Foundation
import Testing
import BridgeProtocol
import ChatCore
import ModelProxy
@testable import Orchestrator

/// Replays scripted model turns and records the request history it was sent.
actor ScriptedModel: ModelClient {
    nonisolated let modelID = "scripted"
    private var turns: [[JSONValue]]
    private(set) var requests: [[JSONValue]] = []
    var onRespond: (@Sendable () async -> Void)?

    init(turns: [[JSONValue]]) {
        self.turns = turns
    }

    func setOnRespond(_ hook: @escaping @Sendable () async -> Void) {
        onRespond = hook
    }

    func respond(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ModelResponse {
        requests.append(messages)
        await onRespond?()
        guard !turns.isEmpty else { throw ModelError.malformedResponse }
        return ModelResponse(content: turns.removeFirst(), stopReason: "tool_use", inputTokens: 100, outputTokens: 10, servedModel: modelID)
    }
}

/// Executes commands in memory; `type` writes the typed text into the outbox to simulate saving a file.
actor FakeGuest: GuestChannel {
    nonisolated let vmID = UUID()
    private(set) var performed: [GuestCommand] = []
    var outbox: URL?

    func setOutbox(_ url: URL) { outbox = url }

    func send(_ envelope: CommandEnvelope) async throws -> CommandResult {
        if case .setLease = envelope.command { return .ok }
        performed.append(envelope.command)
        switch envelope.command {
        case .screenshot:
            return .screenshot(Screenshot(imageData: Data([0x89]), mediaType: "image/png", width: 1280, height: 800, capturedAt: Date(), observationVersion: performed.count))
        case .perform(.type(let text)):
            if let outbox { try Data(text.utf8).write(to: outbox.appendingPathComponent("note.txt")) }
            return .ok
        default:
            return .ok
        }
    }
}

func toolUse(_ id: String, _ name: String, _ input: JSONValue = [:], computer: Bool = true) -> JSONValue {
    var block: [String: JSONValue] = ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
    if computer { block["toolset_name"] = "computer" }
    return .object(block)
}

func makeRunner(model: ScriptedModel, guest: FakeGuest) -> (AgentRunner, SharedFolders) {
    let folders = SharedFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)"))
    let runner = AgentRunner(goal: "Save a note", dependencies: .init(
        model: model, guest: guest, store: InMemoryTaskStore(), lease: ControlLease(), folders: folders))
    return (runner, folders)
}

@Suite struct AgentRunnerTests {
    @Test func completesOnlyWithVerifiedOutput() async throws {
        let model = ScriptedModel(turns: [
            [toolUse("t1", "screenshot"), toolUse("t2", "type", ["text": "hello"])],
            [toolUse("t3", "report_result", ["status": "complete", "summary": "Saved", "outputs": ["note.txt"]], computer: false)],
        ])
        let guest = FakeGuest()
        let (runner, folders) = makeRunner(model: model, guest: guest)
        await guest.setOutbox(folders.outbox(for: await runner.task))

        try await runner.start()

        #expect(await runner.task.phase == .completed)
        // screenshot, type, then the automatic screenshot after the input action.
        #expect(await guest.performed.count == 3)
        // Second request carries both computer results, each echoing toolset_name, then the fresh screen.
        let secondRequest = await model.requests[1]
        let blocks = secondRequest.last?["content"]?.arrayValue ?? []
        let toolResults = blocks.filter { $0["type"] == "tool_result" }
        #expect(toolResults.count == 2)
        #expect(toolResults.allSatisfy { $0["toolset_name"] == "computer" })
        #expect(blocks.last?["type"] == "image")
    }

    @Test func claimedOutputThatDoesNotExistIsRejected() async throws {
        let model = ScriptedModel(turns: [
            [toolUse("t1", "report_result", ["status": "complete", "summary": "Done", "outputs": ["missing.txt"]], computer: false)],
            [.object(["type": "text", "text": "I could not save it."])],
        ])
        let (runner, _) = makeRunner(model: model, guest: FakeGuest())

        try await runner.start()

        // The false completion was refused and fed back as an error, not shown as success.
        #expect(await runner.task.phase != .completed)
        let feedback = await model.requests[1].last?["content"]?.arrayValue?.first
        #expect(feedback?["is_error"] == true)
    }

    @Test func takeoverDuringModelCallBlocksTheWholeBatch() async throws {
        let model = ScriptedModel(turns: [
            [toolUse("t1", "left_click", ["coordinate": [5, 5]]), toolUse("t2", "type", ["text": "x"])],
        ])
        let guest = FakeGuest()
        let (runner, _) = makeRunner(model: model, guest: guest)
        await model.setOnRespond { await runner.takeOver() }

        try await runner.start()

        #expect(await runner.task.phase == .takenOver)
        #expect(await guest.performed.isEmpty)
    }

    @Test func askUserWaitsAndResumesWithTheAnswer() async throws {
        let model = ScriptedModel(turns: [
            [toolUse("t1", "ask_user", ["kind": "approval", "question": "Send the email?", "target": "bob@example.com"], computer: false)],
            [.object(["type": "text", "text": "OK, stopping."])],
        ])
        let (runner, _) = makeRunner(model: model, guest: FakeGuest())

        try await runner.start()
        #expect(await runner.task.phase == .waitingForUser(reason: "Send the email?"))

        await runner.answer("No, don't send it.")
        let reply = await model.requests[1].last?["content"]?.arrayValue?.first
        #expect(reply?["tool_use_id"] == "t1")
        #expect(reply?["content"] == "No, don't send it.")
    }

    @Test func remindsTheModelOnceWhenTurnsRunLow() async throws {
        // 12 screenshot turns under a 12-turn budget: the reminder appears once, when 10 turns are left.
        let model = ScriptedModel(turns: (1...12).map { [toolUse("t\($0)", "screenshot")] })
        let folders = SharedFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)"))
        let runner = AgentRunner(goal: "Look", dependencies: .init(
            model: model, guest: FakeGuest(), store: InMemoryTaskStore(), lease: ControlLease(), folders: folders,
            budget: TaskBudget(maxModelTurns: 12)))

        try await runner.start()

        let requests = await model.requests
        let reminders = requests.enumerated().filter { _, messages in
            messages.last?["content"]?.arrayValue?.contains { $0["text"]?.stringValue?.hasPrefix("Host notice") == true } == true
        }
        #expect(reminders.count == 1)
        #expect(reminders.first?.offset == 2)   // third request: 2 turns used, 10 left
        // Later requests keep it in history (append-only) but do not add another.
        #expect(requests.last?.last?["content"]?.arrayValue?.contains { $0["text"]?.stringValue?.hasPrefix("Host notice") == true } == false)
    }

    @Test func noAutomaticScreenshotWhenTheTurnEndedWithOne() async throws {
        let model = ScriptedModel(turns: [
            [toolUse("t1", "left_click", ["coordinate": [5, 5]]), toolUse("t2", "screenshot")],
            [.object(["type": "text", "text": "Done looking."])],
        ])
        let guest = FakeGuest()
        let (runner, _) = makeRunner(model: model, guest: guest)

        try await runner.start()

        #expect(await guest.performed.count == 2)
        #expect(await model.requests[1].last?["content"]?.arrayValue?.contains { $0["type"] == "image" } == false)
    }

    @Test func stepDescriptionsShowWhatTheActionDid() {
        #expect(AgentRunner.describe(name: "left_click", input: ["coordinate": [512, 300]]) == "left_click [512, 300]")
        #expect(AgentRunner.describe(name: "type", input: ["text": "Hello"]) == "type \"Hello\"")
        #expect(AgentRunner.describe(name: "key", input: ["text": "cmd+s"]) == "key cmd+s")
    }
}

@Suite struct RunnerCheckpointTests {
    /// A task paused mid-way (as the app does on quit), saved as JSON, restored in a new runner and continued
    /// finishes with the full, unchanged conversation.
    @Test func pausedTaskContinuesAfterRestore() async throws {
        let model = ScriptedModel(turns: [
            [.object(["type": "thinking", "thinking": "plan", "signature": "sig-1"]), toolUse("t1", "type", ["text": "hello"])],
            // The paused turn's typing never ran (the model is told so), so after the restore it types again.
            [toolUse("t1b", "type", ["text": "hello"])],
            [toolUse("t2", "report_result", ["status": "complete", "summary": "Saved", "outputs": ["note.txt"]], computer: false)],
        ])
        let guest = FakeGuest()
        let (runner, folders) = makeRunner(model: model, guest: guest)
        await guest.setOutbox(folders.outbox(for: await runner.task))
        // Pause while the model answers the first request, as quitting the app would.
        await model.setOnRespond { await runner.pause() }
        try await runner.start()
        #expect(await runner.task.phase == .paused)

        let data = try JSONEncoder().encode(await runner.checkpoint())
        let saved = try JSONDecoder().decode(AgentRunner.Checkpoint.self, from: data)
        await model.setOnRespond {}
        let restored = AgentRunner(restoring: saved, dependencies: .init(
            model: model, guest: guest, store: InMemoryTaskStore(), lease: ControlLease(), folders: folders))
        #expect(await restored.task.phase == .paused)
        #expect(await restored.task.id == saved.task.id)

        await restored.resume()
        #expect(await restored.task.phase == .completed)
        // The assistant turn from before the restore went back unchanged, signature included.
        let history = await model.requests.last ?? []
        let firstAssistant = history.first { $0["role"] == "assistant" }
        #expect(firstAssistant?["content"]?.arrayValue?.first?["signature"] == "sig-1")
    }

    /// Quitting while an action runs: the checkpoint is taken before the turn's results are recorded.
    /// The restored conversation must still answer every tool call.
    @Test func checkpointMidActionAnswersEveryToolCall() async throws {
        let model = ScriptedModel(turns: [
            [toolUse("t1", "key", ["text": "cmd+s"]), toolUse("t2", "type", ["text": "x"])],
            [toolUse("t3", "screenshot")],
        ])
        let guest = SlowGuest()
        let folders = SharedFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)"))
        let runner = AgentRunner(goal: "Save", dependencies: .init(model: model, guest: guest, store: InMemoryTaskStore(), lease: ControlLease(), folders: folders))
        let started = Task { try await runner.start() }
        // Pause and checkpoint while the first action is still running in the guest.
        while await guest.inFlight == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await runner.pause()
        let checkpoint = await runner.checkpoint()
        let answered = Set(checkpoint.pendingResults.compactMap { $0["tool_use_id"]?.stringValue })
        #expect(answered == ["t1", "t2"])
        await guest.release()
        _ = try? await started.value
    }

    @Test func runningTaskRestoresPausedAndQuestionsStillWait() {
        let task = TaskRecord(goal: "x", phase: .running, modelID: "m")
        let checkpoint = AgentRunner.Checkpoint(task: task, messages: [], pendingResults: [], pendingQuestionID: nil, usage: .init(), warnedAboutTurns: false)
        let deps = AgentRunner.Dependencies(model: ScriptedModel(turns: []), guest: FakeGuest(), store: InMemoryTaskStore(), lease: ControlLease(),
                                            folders: SharedFolders(root: FileManager.default.temporaryDirectory))
        #expect(AgentRunner(restoring: checkpoint, dependencies: deps).initialPhase == .paused)
        var waiting = checkpoint
        waiting.task.phase = .waitingForUser(reason: "Which file?")
        waiting.pendingQuestionID = "q1"
        #expect(AgentRunner(restoring: waiting, dependencies: deps).initialPhase == .waitingForUser(reason: "Which file?"))
    }
}

@Suite struct FileTaskStoreTests {
    @Test func tasksAndEventsSurviveOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileTaskStore-\(UUID().uuidString)")
        let store = FileTaskStore(root: root)
        var task = TaskRecord(goal: "Write a note", modelID: "m")
        try await store.create(task)
        try await store.append(TaskEvent(taskID: task.id, kind: .userMessage("Write a note")))
        try await store.append(TaskEvent(taskID: task.id, kind: .usage(inputTokens: 10, outputTokens: 2)))
        task.phase = .completed
        try await store.update(task)
        // A torn last line (a crash mid-write) is skipped.
        let log = root.appendingPathComponent("\(task.id.uuidString)/events.jsonl")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"taskID\":".utf8))
        try handle.close()

        let reopened = FileTaskStore(root: root)
        #expect(await reopened.task(task.id)?.phase == .completed)
        #expect(await reopened.events(for: task.id).map(\.kind) == [.userMessage("Write a note"), .usage(inputTokens: 10, outputTokens: 2)])
        #expect(await reopened.allTasks().map(\.id) == [task.id])
    }
}

/// A guest whose input actions wait until released, to pause a runner mid-action.
actor SlowGuest: GuestChannel {
    nonisolated let vmID = UUID()
    private(set) var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func send(_ envelope: CommandEnvelope) async throws -> CommandResult {
        if case .perform = envelope.command {
            inFlight += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        if case .screenshot = envelope.command {
            return .screenshot(Screenshot(imageData: Data([0x89]), mediaType: "image/png", width: 1, height: 1, capturedAt: Date(), observationVersion: 1))
        }
        return .ok
    }
}

/// Plays a save dialog: the name is typed first, then the folder; the second Return saves.
actor SaveDialogGuest: GuestChannel {
    nonisolated let vmID = UUID()
    private(set) var inputs: [ComputerAction] = []
    var hostFolder: URL?
    var appendExtension: String?
    private var typed: [String] = []
    private var returns = 0

    func setHostFolder(_ url: URL, appending ext: String? = nil) {
        hostFolder = url
        appendExtension = ext
    }

    func send(_ envelope: CommandEnvelope) async throws -> CommandResult {
        switch envelope.command {
        case .perform(let action):
            inputs.append(action)
            if case .type(let text) = action { typed.append(text) }
            if case .key("return", _) = action {
                returns += 1
                if returns == 2, let hostFolder, let name = typed.first {
                    try FileManager.default.createDirectory(at: hostFolder, withIntermediateDirectories: true)
                    try Data("saved".utf8).write(to: hostFolder.appendingPathComponent(name + (appendExtension ?? "")))
                }
            }
            return .ok
        case .screenshot:
            return .screenshot(Screenshot(imageData: Data([0x89]), mediaType: "image/png", width: 1, height: 1, capturedAt: Date(), observationVersion: 1))
        default:
            return .ok
        }
    }
}

@Suite struct SaveDialogTests {
    /// With screen reading: clicks each field before typing (the panel drops typing after a shortcut until a
    /// click), selects with Down and Shift+Up rather than Cmd+A, waits for the sheet, and retypes lost text.
    @Test func clicksEachFieldAndRetypesLostText() async {
        let log = InputLog()
        let lookups = InputLog()
        let outcome = await SaveDialog.run(name: "a.txt", folder: "/Volumes/My Shared Files/outbox/job", openDialog: true,
            send: { await log.add("\($0)"); return true },
            locate: { text in
                await lookups.add(text)
                let count = await lookups.count(text)
                switch text {
                case "Go to Folder": return count >= 3 ? ScreenPoint(x: 400, y: 200) : nil   // ready on the third look
                case "Save As": return ScreenPoint(x: 300, y: 150)
                case "Export As": return nil
                default: return count >= 2 ? ScreenPoint(x: 400, y: 200) : nil             // name and path lost the first time
                }
            },
            sleep: { _ in })
        #expect(outcome == .pressedSave)
        let inputs = await log.items
        #expect(inputs.filter { $0.contains("outbox/job") }.count == 2)
        #expect(inputs.filter { $0.contains("a.txt") }.count == 2)
        #expect(await lookups.count("Go to Folder") == 3)
        #expect(!inputs.contains { $0.contains("cmd+a") })
        // The name field, right of its label, is clicked before the name is typed.
        let nameClick = inputs.firstIndex { $0.contains("click") && $0.contains("450") }
        #expect(nameClick != nil && nameClick! < inputs.firstIndex { $0.contains("a.txt") }!)
        #expect(inputs.firstIndex { $0.contains("a.txt") }! < inputs.firstIndex { $0.contains("outbox/job") }!)
    }

    /// No dialog on screen: nothing is typed, so the document is not overwritten.
    @Test func typesNothingWithoutADialog() async {
        let log = InputLog()
        let outcome = await SaveDialog.run(name: "a.txt", folder: "/tmp", openDialog: true,
            send: { await log.add("\($0)"); return true }, locate: { _ in nil }, sleep: { _ in })
        #expect(outcome == .noDialog)
        #expect(await log.items.count == 1)   // just Cmd+S
    }

    actor InputLog {
        private(set) var items: [String] = []
        func add(_ item: String) { items.append(item) }
        func count(_ item: String) -> Int { items.filter { $0 == item }.count }
    }
}

@Suite struct SaveFileTests {
    private func run(_ turns: [[JSONValue]], ext: String? = nil) async throws -> (AgentRunner, ScriptedModel, SaveDialogGuest) {
        let model = ScriptedModel(turns: turns)
        let guest = SaveDialogGuest()
        let folders = SharedFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)"))
        let runner = AgentRunner(goal: "Save", dependencies: .init(model: model, guest: guest, store: InMemoryTaskStore(), lease: ControlLease(), folders: folders))
        await guest.setHostFolder(folders.outbox(for: await runner.task), appending: ext)
        try await runner.start()
        return (runner, model, guest)
    }

    @Test func savesWithTheFixedSequenceAndTheHostConfirms() async throws {
        let (runner, model, guest) = try await run([
            [toolUse("s1", "save_file", ["name": "note.txt"], computer: false)],
            [toolUse("r1", "report_result", ["status": "complete", "summary": "Saved", "outputs": ["note.txt"]], computer: false)],
        ])
        #expect(await runner.task.phase == .completed)
        let outbox = SharedFolders.guestOutboxPath(for: await runner.task)
        let expected: [ComputerAction] = [
            .key(combo: "cmd+s", repeat: 1),
            .key(combo: "down", repeat: 1), .key(combo: "shift+up", repeat: 1), .type(text: "note.txt"),
            .key(combo: "cmd+shift+g", repeat: 1),
            .key(combo: "down", repeat: 1), .key(combo: "shift+up", repeat: 1), .type(text: outbox), .key(combo: "return", repeat: 1),
            .key(combo: "return", repeat: 1),
        ]
        #expect(await guest.inputs == expected)
        let result = await model.requests[1].last?["content"]?.arrayValue?.first { $0["tool_use_id"] == "s1" }
        #expect(result?["content"]?.stringValue?.hasPrefix("Saved: note.txt is in the outbox") == true)
    }

    @Test func fileSavedElsewhereIsAnError() async throws {
        let (_, model, _) = try await run([
            [toolUse("s1", "save_file", ["name": "list", "folder": "Reports"], computer: false)],
            [.object(["type": "text", "text": "done"])],
        ], ext: ".rtf")
        let result = await model.requests[1].last?["content"]?.arrayValue?.first { $0["tool_use_id"] == "s1" }
        // The guest saved into the outbox root, not Reports, so the host does not find it there.
        #expect(result?["is_error"] == true)
    }

    @Test func createsAMissingOutboxSubfolderAndRefusesEscapes() async throws {
        let model = ScriptedModel(turns: [
            [toolUse("s1", "save_file", ["name": "summary.txt", "folder": "Reports/Q3"], computer: false)],
            [toolUse("s2", "save_file", ["name": "x.txt", "folder": "../elsewhere"], computer: false)],
            [.object(["type": "text", "text": "done"])],
        ])
        let folders = SharedFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)"))
        let runner = AgentRunner(goal: "Save", dependencies: .init(model: model, guest: SaveDialogGuest(), store: InMemoryTaskStore(), lease: ControlLease(), folders: folders))
        try await runner.start()
        var isDirectory: ObjCBool = false
        let created = folders.outbox(for: await runner.task).appendingPathComponent("Reports/Q3")
        #expect(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let second = await model.requests[2].last?["content"]?.arrayValue?.first { $0["tool_use_id"] == "s2" }
        #expect(second?["content"]?.stringValue?.contains("inside the outbox") == true)
    }

    @Test func missingFileIsAnErrorTheModelSees() async throws {
        let model = ScriptedModel(turns: [
            [toolUse("s1", "save_file", ["name": "a/b.txt"], computer: false)],
            [.object(["type": "text", "text": "ok"])],
        ])
        let folders = SharedFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)"))
        let guest = SaveDialogGuest()
        let runner = AgentRunner(goal: "Save", dependencies: .init(model: model, guest: guest, store: InMemoryTaskStore(), lease: ControlLease(), folders: folders))
        try await runner.start()
        let result = await model.requests[1].last?["content"]?.arrayValue?.first { $0["tool_use_id"] == "s1" }
        #expect(result?["is_error"] == true)
        #expect(await guest.inputs.isEmpty)   // an invalid name types nothing
    }

    @Test func extensionAddedByTheAppStillCounts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("list.rtf"))
        #expect(SaveDialog.savedFiles(named: "list", in: folder).map(\.lastPathComponent) == ["list.rtf"])
        #expect(SaveDialog.savedFiles(named: "list.rtf", in: folder).map(\.lastPathComponent) == ["list.rtf"])
        #expect(SaveDialog.savedFiles(named: "other", in: folder).isEmpty)
        #expect(SaveDialog.extensionWarning(requested: "list", saved: folder.appendingPathComponent("list.rtf")) == nil)
        #expect(SaveDialog.extensionWarning(requested: "a.txt", saved: folder.appendingPathComponent("a.txt.rtf"))?.contains("Make Plain Text") == true)
        #expect(!SaveDialog.isValidName("a/b.txt"))
        #expect(SaveDialog.isValidName("report 2.pdf"))
    }
}
