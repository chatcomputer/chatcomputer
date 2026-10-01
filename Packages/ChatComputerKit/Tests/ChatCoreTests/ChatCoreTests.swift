import Foundation
import Testing
@testable import ChatCore

@Suite struct TaskPhaseTests {
    @Test func takeoverHandsBackIntoPausedNotRunning() throws {
        let running = try TaskPhase.ready.applying(.start)
        let takenOver = try running.applying(.userTookOver)
        #expect(takenOver == .takenOver)
        // Returning control must not resume dispatch directly; the agent re-observes first.
        #expect(try takenOver.applying(.userReturnedControl) == .paused)
        #expect(throws: InvalidTransition.self) { try takenOver.applying(.resume) }
    }

    @Test func terminalPhasesAreFinal() {
        for phase in [TaskPhase.completed, .cancelled, .failed(reason: "x")] {
            #expect(throws: InvalidTransition.self) { try phase.applying(.start) }
            #expect(throws: InvalidTransition.self) { try phase.applying(.cancel) }
        }
    }

    @Test func onlyRunningAllowsDispatch() {
        #expect(TaskPhase.running.allowsDispatch)
        #expect(!TaskPhase.paused.allowsDispatch)
        #expect(!TaskPhase.waitingForUser(reason: "login").allowsDispatch)
    }
}

@Suite struct ControlLeaseTests {
    @Test func userTakeoverInvalidatesAgentToken() async throws {
        let lease = ControlLease()
        let token = try await lease.acquireForAgent()
        #expect(await lease.isValid(token))
        await lease.grantToUser()
        #expect(!(await lease.isValid(token)))
        await #expect(throws: LeaseError.heldByUser) { try await lease.acquireForAgent() }
    }
}

@Suite struct ExportValidatorTests {
    let outbox: URL

    init() throws {
        outbox = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    }

    @Test func acceptsRegularFileInsideOutbox() throws {
        try Data("hello".utf8).write(to: outbox.appendingPathComponent("note.txt"))
        let result = try ExportValidator().validate(relativePath: "note.txt", in: outbox)
        #expect(result.bytes == 5)
    }

    @Test func rejectsTraversalAndAbsolutePaths() {
        let validator = ExportValidator()
        #expect(throws: ExportValidator.Rejection.invalidName) { try validator.validate(relativePath: "../secret", in: outbox) }
        #expect(throws: ExportValidator.Rejection.invalidName) { try validator.validate(relativePath: "/etc/passwd", in: outbox) }
    }

    @Test func rejectsSymlinkEscapingOutbox() throws {
        let link = outbox.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
        #expect(throws: ExportValidator.Rejection.symbolicLink) { try ExportValidator().validate(relativePath: "link.txt", in: outbox) }
    }

    @Test func rejectsMissingAndOversizedFiles() throws {
        #expect(throws: ExportValidator.Rejection.missing) { try ExportValidator().validate(relativePath: "nope.txt", in: outbox) }
        try Data(count: 10).write(to: outbox.appendingPathComponent("big.bin"))
        #expect(throws: ExportValidator.Rejection.tooLarge(10)) { try ExportValidator(maxBytes: 5).validate(relativePath: "big.bin", in: outbox) }
    }
}

@Suite struct BudgetTests {
    @Test func reportsFirstExhaustedLimit() {
        var usage = BudgetUsage()
        #expect(usage.exceeded(TaskBudget()) == nil)
        usage.consecutiveFailures = 3
        #expect(usage.exceeded(TaskBudget(maxConsecutiveFailures: 3)) != nil)
    }
}
