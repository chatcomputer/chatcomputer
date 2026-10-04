import Foundation
import BridgeProtocol
import ChatCore
import ModelProxy

/// What the UI needs to render a running task.
public enum RunnerUpdate: Sendable, Equatable {
    case phase(TaskPhase)
    case assistantNote(String)
    case action(String)
    case needsUser(HostTools.AskUser)
    case usage(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int)
    case delivered([URL])
    /// A request to the model is about to go out: turn `turn` of at most `of`.
    case thinking(turn: Int, of: Int)
    /// Something the user should know that isn't from the model: a retry, why the task paused.
    case notice(String)
}

/// The agent loop (proposal §06): observe → act → re-observe, with every dispatch gated
/// by task phase, control lease and budget — all checked outside the model.
///
/// Control methods (`pause`, `takeOver`, `cancel`) may run while `run()` is suspended on the
/// model or the guest; actor re-entrancy is what lets them take effect immediately.
public actor AgentRunner {
    public struct Dependencies: Sendable {
        public var model: any ModelClient
        public var guest: any GuestChannel
        public var store: any TaskStore
        public var lease: ControlLease
        public var folders: SharedFolders
        public var budget: TaskBudget
        public var exportValidator: ExportValidator
        /// After a turn of input actions, attach a fresh screenshot so the model sees the result without
        /// spending a turn on asking for one.
        public var screenshotAfterActions: Bool
        /// Finds text in a screenshot (PNG or JPEG) and returns where it is, in the screenshot's coordinates.
        /// Supplied on macOS (Vision); without it, steps that click on text are skipped.
        public var locateText: (@Sendable (Data, String) async -> ScreenPoint?)?
        /// Pauses before resending a request that failed for a transient reason (rate limit, overload, 5xx,
        /// network). A provider's retry-after replaces the pause when longer, up to a minute.
        public var modelRetryDelays: [TimeInterval] = [2, 8, 20]

        public init(model: any ModelClient, guest: any GuestChannel, store: any TaskStore, lease: ControlLease, folders: SharedFolders, budget: TaskBudget = .init(), exportValidator: ExportValidator = .init(), screenshotAfterActions: Bool = true) {
            self.screenshotAfterActions = screenshotAfterActions
            self.model = model
            self.guest = guest
            self.store = store
            self.lease = lease
            self.folders = folders
            self.budget = budget
            self.exportValidator = exportValidator
        }
    }

    public nonisolated let updates: AsyncStream<RunnerUpdate>
    private let continuation: AsyncStream<RunnerUpdate>.Continuation

    private let deps: Dependencies
    public private(set) var task: TaskRecord
    private var messages: [JSONValue] = []
    private var usage = BudgetUsage()
    private var leaseToken: UUID?
    private var observationVersion: Int?
    /// Bumped by every pause/takeover/cancel so an in-flight turn knows it was interrupted.
    private var generation = 0
    private var isLooping = false
    /// Tool results owed to the model from an interrupted turn; sent with the next user message.
    private var pendingResults: [JSONValue] = []
    /// The `ask_user` call waiting for the user's answer.
    private var pendingQuestionID: String?
    /// Whether the model has been told its turns are running out (once per task).
    private var warnedAboutTurns = false
    /// Turns left when that reminder is sent.
    static let turnReminderThreshold = 10

    /// Files the user attached; copied into the task's inbox when it starts.
    private let attachments: [URL]

    public init(goal: String, attachments: [URL] = [], dependencies: Dependencies) {
        self.deps = dependencies
        self.attachments = attachments
        self.task = TaskRecord(goal: goal, modelID: dependencies.model.modelID)
        self.initialPhase = .ready
        (updates, continuation) = AsyncStream.makeStream()
    }

    /// Everything needed to pick a task up again after the app quits: the conversation with the model
    /// (unchanged, thinking blocks included), tool results it is still owed, and the budget spent.
    public struct Checkpoint: Codable, Sendable {
        public var task: TaskRecord
        public var messages: [JSONValue]
        public var pendingResults: [JSONValue]
        public var pendingQuestionID: String?
        public var usage: BudgetUsage
        public var warnedAboutTurns: Bool
    }

    /// The task's phase when this runner was created (`.paused` for one restored mid-work).
    public nonisolated let initialPhase: TaskPhase

    /// A consistent picture of the task. Taken while a turn is still being handled (the app quitting mid-action),
    /// the last assistant turn may have tool calls whose results aren't recorded yet; every request must answer
    /// each call, so those get a result saying the action may or may not have happened.
    public func checkpoint() -> Checkpoint {
        var results = pendingResults
        if let last = messages.last, last["role"] == "assistant" {
            let answered = Set(results.compactMap { $0["tool_use_id"]?.stringValue })
            for block in last["content"]?.arrayValue ?? [] where block["type"] == "tool_use" {
                guard let id = block["id"]?.stringValue, !answered.contains(id), id != pendingQuestionID else { continue }
                let note = "Interrupted: Chat Computer quit while this was running, so it may or may not have happened. Take a screenshot before continuing."
                results.append(block["toolset_name"] == .string(ComputerToolset.toolsetName)
                    ? ComputerToolset.textResult(toolUseID: id, note, isError: true)
                    : HostTools.result(toolUseID: id, note, isError: true))
            }
        }
        return Checkpoint(task: task, messages: messages, pendingResults: results, pendingQuestionID: pendingQuestionID,
                          usage: usage, warnedAboutTurns: warnedAboutTurns)
    }

    /// Restores a task saved by `checkpoint()`. One that was working comes back paused, so it continues only
    /// when the user says so (`resume`); one waiting for the user's answer still waits for it.
    public init(restoring saved: Checkpoint, dependencies: Dependencies) {
        self.deps = dependencies
        self.attachments = []
        var task = saved.task
        switch task.phase {
        case .running, .takenOver, .waitingExternal: task.phase = .paused
        default: break
        }
        self.task = task
        self.initialPhase = task.phase
        self.messages = saved.messages
        self.pendingResults = saved.pendingResults
        self.pendingQuestionID = saved.pendingQuestionID
        self.usage = saved.usage
        self.warnedAboutTurns = saved.warnedAboutTurns
        (updates, continuation) = AsyncStream.makeStream()
    }

    // MARK: - Control (called from the UI)

    public func start() async throws {
        try deps.folders.prepare(task: task)
        let attached = try deps.folders.attach(attachments, to: task)
        try await deps.store.create(task)
        try await deps.store.append(TaskEvent(taskID: task.id, kind: .userMessage(task.goal)))
        var request = task.goal
        if !attached.isEmpty {
            let inbox = SharedFolders.guestInboxPath(for: task)
            request += "\n\nAttached files (read-only, in the virtual Mac):\n" + attached.map { "- \(inbox)/\($0)" }.joined(separator: "\n")
        }
        messages.append(["role": "user", "content": .string(request)])
        try await transition(.start)
        await run()
    }

    public func pause() async {
        generation += 1
        await revokeLease()
        try? await transition(.pause)
    }

    /// The user clicked into the VM view. Revokes the agent's input before anything else.
    public func takeOver() async {
        generation += 1
        await deps.lease.grantToUser()
        leaseToken = nil
        _ = try? await deps.guest.send(envelope(.setLease(nil)))
        try? await transition(.userTookOver)
    }

    public func returnControl() async {
        await deps.lease.releaseFromUser()
        try? await transition(.userReturnedControl)
    }

    public func resume() async {
        guard task.phase == .paused else { return }
        if let id = pendingQuestionID {
            pendingResults.append(HostTools.result(toolUseID: id, "The user paused instead of answering. Ask again if it is still needed."))
            pendingQuestionID = nil
        }
        pendingResults.append(["type": "text", "text": "The user paused and resumed the task; the screen may have changed. Take a fresh screenshot before acting."])
        try? await transition(.resume)
        await run()
    }

    /// The user's reply to an `ask_user` call, or to a plain question at the end of a turn.
    public func answer(_ text: String) async {
        guard case .waitingForUser = task.phase else { return }
        try? await deps.store.append(TaskEvent(taskID: task.id, kind: .userMessage(text)))
        if let id = pendingQuestionID {
            pendingResults.append(HostTools.result(toolUseID: id, text))
            pendingQuestionID = nil
        } else {
            pendingResults.append(["type": "text", "text": .string(text)])
        }
        try? await transition(.userResolved)
        await run()
    }

    public func cancel() async {
        generation += 1
        await revokeLease()
        try? await transition(.cancel)
    }

    // MARK: - Loop

    /// One model request, sent again after a pause when it fails for a transient reason. Gives up early if the
    /// task was paused or cancelled meanwhile.
    private func respondRetrying(generation turnGeneration: Int) async throws -> ModelResponse {
        var attempt = 0
        while true {
            do {
                return try await deps.model.respond(
                    system: SystemPrompt.make(
                        outboxPath: SharedFolders.guestOutboxPath(for: task),
                        inboxPath: SharedFolders.guestInboxPath(for: task)
                    ),
                    tools: [ComputerToolset.definition] + HostTools.definitions,
                    messages: messages
                )
            } catch let error as ModelError where error.isTransient && attempt < deps.modelRetryDelays.count {
                var delay = deps.modelRetryDelays[attempt]
                if case .rateLimited(let retryAfter?) = error { delay = max(delay, min(retryAfter, 60)) }
                attempt += 1
                continuation.yield(.notice("\(error.explanation) Trying again in \(Int(delay.rounded())) s (\(attempt) of \(deps.modelRetryDelays.count))."))
                try? await Task.sleep(for: .seconds(delay))
                guard turnGeneration == generation, task.phase == .running else { throw error }
            }
        }
    }

    public func run() async {
        guard !isLooping else { return }
        isLooping = true
        defer { isLooping = false }

        do {
            leaseToken = try await deps.lease.acquireForAgent()
            _ = try await deps.guest.send(envelope(.setLease(leaseToken)))
        } catch {
            try? await transition(.fail("Could not take control of the VM: \(error)"))
            return
        }

        while task.phase == .running {
            if let exhausted = usage.exceeded(deps.budget) {
                try? await transition(.fail("Stopped: \(exhausted) reached."))
                break
            }
            // Some models keep re-checking finished work instead of reporting. A plain reminder
            // near the limit (outside the model's control, like every other budget rule) lets the
            // task end with a verified result instead of running out of turns.
            let turnsLeft = deps.budget.maxModelTurns - usage.modelTurns
            if !warnedAboutTurns, turnsLeft <= Self.turnReminderThreshold, !pendingResults.isEmpty {
                warnedAboutTurns = true
                pendingResults.append(["type": "text", "text": .string("""
                    Host notice: \(turnsLeft) model turns are left for this task. If the work is done, call report_result now; \
                    it checks that the listed files exist in the outbox, so you do not need to verify them yourself. \
                    If it is not done, finish the essential steps first.
                    """)])
            }
            if !pendingResults.isEmpty {
                messages.append(["role": "user", "content": .array(pendingResults)])
                pendingResults = []
            }

            continuation.yield(.thinking(turn: usage.modelTurns + 1, of: deps.budget.maxModelTurns))
            let turnGeneration = generation
            let response: ModelResponse
            do {
                response = try await respondRetrying(generation: turnGeneration)
            } catch let error as ModelError {
                guard turnGeneration == generation, task.phase == .running else { break }
                if error.userCanFix {
                    // Keep the task: the conversation ends with the request, so Continue sends it again.
                    continuation.yield(.notice("Paused: \(error.explanation) Press Continue to try again."))
                    await pause()
                } else {
                    try? await transition(.fail("Model error: \(error.explanation)"))
                }
                break
            } catch {
                guard turnGeneration == generation, task.phase == .running else { break }
                try? await transition(.fail("Model error: \(error)"))
                break
            }

            usage.modelTurns += 1
            usage.inputTokens += response.inputTokens
            usage.outputTokens += response.outputTokens
            usage.cachedInputTokens += response.cachedInputTokens
            task.inputTokens = usage.inputTokens
            task.outputTokens = usage.outputTokens
            try? await deps.store.append(TaskEvent(taskID: task.id, kind: .usage(inputTokens: response.inputTokens, outputTokens: response.outputTokens)))
            continuation.yield(.usage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, cachedInputTokens: usage.cachedInputTokens))

            // Assistant content goes back unchanged, thinking blocks included.
            messages.append(["role": "assistant", "content": .array(response.content)])
            await handle(response, turnGeneration: turnGeneration)
        }
        await revokeLease()
    }

    private func handle(_ response: ModelResponse, turnGeneration: Int) async {
        var results: [JSONValue] = []
        var batchFailed = false
        var sawToolUse = false
        var lastText = ""
        var changedScreen = false
        var lastWasScreenshot = false

        for block in response.blocks {
            switch block {
            case .text(let text) where !text.isEmpty, .thinking(let text) where !text.isEmpty:
                lastText = text
                continuation.yield(.assistantNote(text))
                try? await deps.store.append(TaskEvent(taskID: task.id, kind: .assistantNote(text)))

            case .toolUse(let id, let name, let toolsetName, let input):
                sawToolUse = true
                let interrupted = generation != turnGeneration || task.phase != .running
                if toolsetName == ComputerToolset.toolsetName {
                    if batchFailed || interrupted {
                        results.append(ComputerToolset.notExecuted(toolUseID: id))
                        continue
                    }
                    let result = await perform(toolUseID: id, name: name, input: input)
                    results.append(result.json)
                    batchFailed = !result.succeeded
                    lastWasScreenshot = name == "screenshot" || name == "zoom"
                    if !lastWasScreenshot, !Self.passiveActions.contains(name) { changedScreen = true }
                } else if name == HostTools.askUser, let ask = HostTools.parseAskUser(input) {
                    pendingQuestionID = id
                    continuation.yield(.needsUser(ask))
                    if !interrupted { try? await transition(.needUser(ask.question)) }
                } else if name == HostTools.saveFile, let request = HostTools.parseSaveFile(input) {
                    if batchFailed || interrupted {
                        results.append(HostTools.result(toolUseID: id, "Not executed: an earlier action in this turn failed or the task was paused.", isError: true))
                        continue
                    }
                    let result = await saveFile(toolUseID: id, request)
                    results.append(result.json)
                    batchFailed = !result.succeeded
                    changedScreen = true
                    lastWasScreenshot = false
                } else if name == HostTools.reportResult, let report = HostTools.parseReport(input) {
                    results.append(await finish(toolUseID: id, report: report))
                } else {
                    results.append(HostTools.result(toolUseID: id, "Unknown tool or invalid input.", isError: true))
                }

            default:
                continue
            }
        }

        if deps.screenshotAfterActions, changedScreen, !lastWasScreenshot, !batchFailed,
           generation == turnGeneration, task.phase == .running,
           let image = await screenshotBlock() {
            results.append(["type": "text", "text": "Screen after your actions:"])
            results.append(image)
        }
        pendingResults.append(contentsOf: results)

        // A turn that ends without tools is the model talking to the user; wait for a reply.
        if !sawToolUse, task.phase == .running {
            try? await transition(.needUser(lastText.isEmpty ? "The agent is waiting for your reply." : lastText))
        }
    }

    /// Actions that never change what is on screen.
    static let passiveActions: Set<String> = ["cursor_position", "wait"]

    /// A screenshot as a plain image block, for the automatic after-actions view.
    private func screenshotBlock() async -> JSONValue? {
        // Give animations and window changes a moment to settle.
        try? await Task.sleep(for: .milliseconds(600))
        guard case .screenshot(let shot)? = try? await deps.guest.send(envelope(.screenshot(region: nil))) else { return nil }
        observationVersion = shot.observationVersion
        return [
            "type": "image",
            "source": ["type": "base64", "media_type": .string(shot.mediaType), "data": .string(shot.imageData.base64EncodedString())],
        ]
    }

    private func perform(toolUseID: String, name: String, input: JSONValue) async -> (json: JSONValue, succeeded: Bool) {
        let command: GuestCommand
        do {
            command = try ComputerToolset.command(name: name, input: input)
        } catch {
            return (ComputerToolset.textResult(toolUseID: toolUseID, "\(error)", isError: true), false)
        }

        // Gate every input action on the lease, outside the model (proposal §06 step 5).
        if command.requiresLease {
            guard let token = leaseToken, await deps.lease.isValid(token) else {
                return (ComputerToolset.textResult(toolUseID: toolUseID, "Not executed: the agent no longer holds input control.", isError: true), false)
            }
            usage.actions += 1
        }

        let stepID = UUID()
        try? await deps.store.append(TaskEvent(taskID: task.id, kind: .step(stepID: stepID, status: .dispatched, summary: name)))
        continuation.yield(.action(Self.describe(name: name, input: input)))

        do {
            let result = try await deps.guest.send(envelope(command))
            switch result {
            case .screenshot(let screenshot):
                observationVersion = screenshot.observationVersion
                usage.consecutiveFailures = 0
                try? await deps.store.append(TaskEvent(taskID: task.id, kind: .step(stepID: stepID, status: .observed, summary: name)))
                return (ComputerToolset.imageResult(toolUseID: toolUseID, screenshot: screenshot), true)
            case .cursor(let point):
                usage.consecutiveFailures = 0
                return (ComputerToolset.textResult(toolUseID: toolUseID, "X=\(point.x),Y=\(point.y)"), true)
            case .ok, .health, .capabilities:
                usage.consecutiveFailures = 0
                return (ComputerToolset.textResult(toolUseID: toolUseID, "OK"), true)
            case .failure(let error):
                usage.consecutiveFailures += 1
                try? await deps.store.append(TaskEvent(taskID: task.id, kind: .step(stepID: stepID, status: .failed, summary: error.message)))
                return (ComputerToolset.textResult(toolUseID: toolUseID, "\(error.category.rawValue): \(error.message)", isError: true), false)
            }
        } catch {
            // Lost connection mid-action: we cannot tell whether it happened.
            usage.consecutiveFailures += 1
            try? await deps.store.append(TaskEvent(taskID: task.id, kind: .step(stepID: stepID, status: .uncertain, summary: "\(error)")))
            return (ComputerToolset.textResult(toolUseID: toolUseID, "Unknown whether the action ran (\(error)). Take a screenshot to check.", isError: true), false)
        }
    }

    /// Completion requires evidence: every reported output must exist in the outbox.
    /// Fills in the save dialog with a fixed key sequence (`SaveDialog`), then checks on the host that the file
    /// arrived when it was saved into the outbox, so the model needn't look for it.
    private func saveFile(toolUseID: String, _ request: HostTools.SaveFile) async -> (json: JSONValue, succeeded: Bool) {
        guard SaveDialog.isValidName(request.name) else {
            return (HostTools.result(toolUseID: toolUseID, "The name must be a plain file name, without folders.", isError: true), false)
        }
        let outbox = SharedFolders.guestOutboxPath(for: task)
        var folder = request.folder ?? outbox
        if !folder.hasPrefix("/") { folder = outbox + "/" + folder }
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        continuation.yield(.action("save_file \"\(request.name)\" → \(folder)"))
        // A folder inside the outbox is created on the host first: Go to Folder can't open one that doesn't exist.
        let inOutbox = folder == outbox || folder.hasPrefix(outbox + "/")
        let relative = inOutbox ? String(folder.dropFirst(outbox.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
        guard !relative.split(separator: "/").contains("..") else {
            return (HostTools.result(toolUseID: toolUseID, "The folder must stay inside the outbox.", isError: true), false)
        }
        let hostFolder = relative.isEmpty ? deps.folders.outbox(for: task) : deps.folders.outbox(for: task).appendingPathComponent(relative)
        if inOutbox { try? FileManager.default.createDirectory(at: hostFolder, withIntermediateDirectories: true) }
        let before = SaveDialog.fingerprints(named: request.name, in: hostFolder)

        guard let token = leaseToken, await deps.lease.isValid(token) else {
            return (HostTools.result(toolUseID: toolUseID, "Stopped: the agent no longer holds input control.", isError: true), false)
        }
        let guest = deps.guest
        let lease = deps.lease
        let vmID = deps.guest.vmID
        let jobID = task.id
        @Sendable func envelope(_ command: GuestCommand) -> CommandEnvelope {
            CommandEnvelope(vmID: vmID, jobID: jobID, leaseToken: token, observationVersion: nil, deadline: Date().addingTimeInterval(30), command: command)
        }
        let send: SaveDialog.Send = { action in
            guard await lease.isValid(token) else { return false }
            if case .failure? = try? await guest.send(envelope(.perform(action))) { return false }
            return true
        }
        var locate: SaveDialog.Locate?
        if let find = deps.locateText {
            locate = { (text: String) async -> ScreenPoint? in
                guard case .screenshot(let shot)? = try? await guest.send(envelope(.screenshot(region: nil))) else { return nil }
                return await find(shot.imageData, text)
            }
        }
        usage.actions += 8
        switch await SaveDialog.run(name: request.name, folder: folder, openDialog: request.openDialog, send: send, locate: locate) {
        case .pressedSave: break
        case .refused:
            return (HostTools.result(toolUseID: toolUseID, "Stopped: the virtual Mac refused an input, or the agent lost input control.", isError: true), false)
        case .alreadyExists:
            return (HostTools.result(toolUseID: toolUseID, """
                A file named \(request.name) already exists there, and the dialog asked whether to replace it; it was \
                cancelled and nothing was saved. Call save_file with another name, or replace it yourself only if the user wants that.
                """, isError: true), false)
        case .noDialog:
            return (HostTools.result(toolUseID: toolUseID, """
                No save dialog appeared, so nothing was typed. Take a screenshot. A document opened from the inbox                 is read-only: use File › Duplicate (or Save As…) to get a save dialog, then call save_file with open_dialog: false.
                """, isError: true), false)
        }

        guard inOutbox else {
            return (HostTools.result(toolUseID: toolUseID, "Pressed Save for \(request.name) in \(folder). Take a screenshot to check it worked."), true)
        }
        if let file = SaveDialog.changedFiles(named: request.name, in: hostFolder, before: before).first {
            let path = (relative.isEmpty ? "" : relative + "/") + file.lastPathComponent
            let warning = SaveDialog.extensionWarning(requested: request.name, saved: file) ?? ""
            return (HostTools.result(toolUseID: toolUseID, "Saved: \(path) is in the outbox. List it as \"\(path)\" in report_result." + warning), true)
        }
        return (HostTools.result(toolUseID: toolUseID, """
            The file did not appear in the outbox. Look at the screenshot: a dialog may still be open (asking to replace \
            a file, or about the format), or no save dialog opened (then open it and call save_file with open_dialog: false).
            """, isError: true), false)
    }

    private func finish(toolUseID: String, report: HostTools.ReportResult) async -> JSONValue {
        let outbox = deps.folders.outbox(for: task)
        var delivered: [URL] = []
        var problems: [String] = []
        for path in report.outputs {
            do {
                let file = try deps.exportValidator.validate(relativePath: path, in: outbox)
                delivered.append(file.url)
                try? await deps.store.append(TaskEvent(taskID: task.id, kind: .artifact(path: path, bytes: file.bytes)))
            } catch {
                problems.append("\(path): \(error)")
            }
        }

        if !problems.isEmpty {
            usage.consecutiveFailures += 1
            return HostTools.result(toolUseID: toolUseID, "Not accepted. These outputs failed verification: \(problems.joined(separator: "; "))", isError: true)
        }

        continuation.yield(.assistantNote(report.summary))
        continuation.yield(.delivered(delivered))
        switch report.status {
        case .complete:
            try? await transition(.complete)
        case .partial, .failed:
            try? await transition(.fail(report.summary))
        }
        return HostTools.result(toolUseID: toolUseID, "Verified \(delivered.count) output file(s).")
    }

    // MARK: - Helpers

    /// "left_click [512, 300]", "type \"Hello\"", "key cmd+s": what the step list in the chat shows.
    static func describe(name: String, input: JSONValue) -> String {
        var parts = [name]
        if let point = input["coordinate"]?.arrayValue?.compactMap(\.intValue), point.count == 2 { parts.append("[\(point[0]), \(point[1])]") }
        if let text = input["text"]?.stringValue {
            let short = text.count > 40 ? String(text.prefix(40)) + "…" : text
            parts.append(name == "type" ? "\"\(short)\"" : short)
        }
        if let direction = input["scroll_direction"]?.stringValue { parts.append(direction) }
        return parts.joined(separator: " ")
    }

    private func envelope(_ command: GuestCommand) -> CommandEnvelope {
        var timeout: TimeInterval = 30
        if case .perform(.wait(let seconds)) = command { timeout += seconds }
        if case .perform(.holdKey(_, let seconds)) = command { timeout += seconds }
        return CommandEnvelope(
            vmID: deps.guest.vmID,
            jobID: task.id,
            leaseToken: leaseToken,
            observationVersion: observationVersion,
            deadline: Date().addingTimeInterval(timeout),
            command: command
        )
    }

    private func revokeLease() async {
        guard leaseToken != nil else { return }
        leaseToken = nil
        if case .agent = await deps.lease.holder { await deps.lease.release() }
        _ = try? await deps.guest.send(envelope(.setLease(nil)))
    }

    /// State is persisted before the UI hears about it.
    private func transition(_ trigger: TaskTrigger) async throws {
        let next = try task.phase.applying(trigger)
        task.phase = next
        try await deps.store.update(task)
        try await deps.store.append(TaskEvent(taskID: task.id, kind: .phaseChanged(next)))
        continuation.yield(.phase(next))
        if next.isTerminal { continuation.finish() }
    }
}
