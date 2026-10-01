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
        #expect(await guest.performed.count == 2)
        // Second request carries both computer results, each echoing toolset_name.
        let secondRequest = await model.requests[1]
        let results = secondRequest.last?["content"]?.arrayValue ?? []
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0["toolset_name"] == "computer" })
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
}
