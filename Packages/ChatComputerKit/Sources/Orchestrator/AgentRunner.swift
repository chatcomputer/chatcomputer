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
    case usage(inputTokens: Int, outputTokens: Int)
    case delivered([URL])
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

        public init(model: any ModelClient, guest: any GuestChannel, store: any TaskStore, lease: ControlLease, folders: SharedFolders, budget: TaskBudget = .init(), exportValidator: ExportValidator = .init()) {
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

    public init(goal: String, dependencies: Dependencies) {
        self.deps = dependencies
        self.task = TaskRecord(goal: goal, modelID: dependencies.model.modelID)
        (updates, continuation) = AsyncStream.makeStream()
    }

    // MARK: - Control (called from the UI)

    public func start() async throws {
        try deps.folders.prepare(jobID: task.id)
        try await deps.store.create(task)
        try await deps.store.append(TaskEvent(taskID: task.id, kind: .userMessage(task.goal)))
        messages.append(["role": "user", "content": .string(task.goal)])
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

            let turnGeneration = generation
            let response: ModelResponse
            do {
                response = try await deps.model.respond(
                    system: SystemPrompt.make(
                        outboxPath: SharedFolders.guestOutboxPath(for: task.id),
                        inboxPath: SharedFolders.guestInboxPath(for: task.id)
                    ),
                    tools: [ComputerToolset.definition] + HostTools.definitions,
                    messages: messages
                )
            } catch {
                try? await transition(.fail("Model error: \(error)"))
                break
            }

            usage.modelTurns += 1
            usage.inputTokens += response.inputTokens
            usage.outputTokens += response.outputTokens
            task.inputTokens = usage.inputTokens
            task.outputTokens = usage.outputTokens
            try? await deps.store.append(TaskEvent(taskID: task.id, kind: .usage(inputTokens: response.inputTokens, outputTokens: response.outputTokens)))
            continuation.yield(.usage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens))

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
                } else if name == HostTools.askUser, let ask = HostTools.parseAskUser(input) {
                    pendingQuestionID = id
                    continuation.yield(.needsUser(ask))
                    if !interrupted { try? await transition(.needUser(ask.question)) }
                } else if name == HostTools.reportResult, let report = HostTools.parseReport(input) {
                    results.append(await finish(toolUseID: id, report: report))
                } else {
                    results.append(HostTools.result(toolUseID: id, "Unknown tool or invalid input.", isError: true))
                }

            default:
                continue
            }
        }

        pendingResults.append(contentsOf: results)

        // A turn that ends without tools is the model talking to the user; wait for a reply.
        if !sawToolUse, task.phase == .running {
            try? await transition(.needUser(lastText.isEmpty ? "The agent is waiting for your reply." : lastText))
        }
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
        continuation.yield(.action(name))

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
    private func finish(toolUseID: String, report: HostTools.ReportResult) async -> JSONValue {
        let outbox = deps.folders.outbox(for: task.id)
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
