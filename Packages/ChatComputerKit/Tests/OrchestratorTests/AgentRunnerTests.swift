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
        await guest.setOutbox(folders.outbox(for: await runner.task.id))

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
