#if os(macOS)
import Testing
import Virtualization
@testable import VMKit

@MainActor
struct VMStopOperationTests {
    enum StopFailure: Error { case requested }

    @Test func successfulStopNeedsNoRecovery() async throws {
        var calls = 0
        let error = try await VMStopOperation.run({ calls += 1 }, state: { .stopped })
        #expect(error == nil)
        #expect(calls == 1)
    }

    @Test(arguments: [VZVirtualMachine.State.stopped, .error])
    func terminalStopErrorAllowsTheRequestedFileStep(_ state: VZVirtualMachine.State) async throws {
        var fileStep = false
        let recovered = try await VMStopOperation.run({ throw StopFailure.requested }, state: { state })
        fileStep = true
        #expect(recovered is StopFailure)
        #expect(fileStep)
    }

    @Test(arguments: [VZVirtualMachine.State.running, .paused, .starting, .pausing,
                      .resuming, .stopping, .saving, .restoring])
    func liveOrTransitionalStopErrorCannotReachFileReplacement(_ state: VZVirtualMachine.State) async {
        var fileStep = false
        do {
            _ = try await VMStopOperation.run({ throw StopFailure.requested }, state: { state })
            fileStep = true
            Issue.record("A nonterminal VM was accepted as stopped")
        } catch {
            #expect(error is StopFailure)
        }
        #expect(!fileStep)
    }
}
#endif
