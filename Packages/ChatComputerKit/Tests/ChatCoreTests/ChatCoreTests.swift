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


@Suite struct TaskFolderTests {
    @Test func folderNamesAreReadableAsciiAndStable() {
        var components = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                        year: 2026, month: 10, day: 2, hour: 14, minute: 5)
        components.second = 30
        let task = TaskRecord(id: UUID(uuidString: "3F2A0000-0000-0000-0000-000000000000")!, goal: "写一份报告",
                              createdAt: components.date!, modelID: "m")
        #expect(SharedFolders.folderName(for: task) == "2026-10-02_14-05_3f2a")
        #expect(SharedFolders.guestOutboxPath(for: task) == "/Volumes/My Shared Files/outbox/2026-10-02_14-05_3f2a")
    }

    @Test func attachmentsAreCopiedWithUniqueNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskFolderTests-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: source.appendingPathComponent("a/report.pdf"))
        try Data("2".utf8).write(to: source.appendingPathComponent("b/report.pdf"))
        let folders = SharedFolders(root: root.appendingPathComponent("Shared"))
        let task = TaskRecord(goal: "x", modelID: "m")
        let names = try folders.attach([source.appendingPathComponent("a/report.pdf"), source.appendingPathComponent("b/report.pdf")], to: task)
        #expect(names == ["report.pdf", "report 2.pdf"])
        #expect(try Data(contentsOf: folders.inbox(for: task).appendingPathComponent("report 2.pdf")) == Data("2".utf8))
    }

    @Test func cleanupKeepsRecentAndRunningTaskFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Cleanup-\(UUID().uuidString)")
        let old = Date().addingTimeInterval(-10 * 86400)
        for name in ["old", "running", "fresh", "old-with-new-file"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            let file = root.appendingPathComponent("\(name)/a.txt")
            try Data("abc".utf8).write(to: file)
            if name != "fresh" { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path) }
            if name != "fresh" { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(name).path) }
        }
        try Data("new".utf8).write(to: root.appendingPathComponent("old-with-new-file/b.txt"))
        #expect(SharedFolders.usage(of: root).files == 5)

        let removed = try SharedFolders.removeItems(in: root, olderThan: Date().addingTimeInterval(-7 * 86400), keeping: ["running"])
        #expect(removed == 1)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["running", "fresh", "old-with-new-file"])
    }
}
