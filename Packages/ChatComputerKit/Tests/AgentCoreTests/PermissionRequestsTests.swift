#if os(macOS)
import BridgeProtocol
import Foundation
import Testing
@testable import AgentCore

private actor RequestGate {
    private var pending: CheckedContinuation<Bool, Never>?
    private(set) var count = 0
    func wait() async -> Bool {
        count += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func release() { pending?.resume(returning: false); pending = nil }
}

@MainActor
@Suite struct PermissionRequestsTests {
    @Test func pendingSystemPromptDoesNotBlockObservationOrCreateAnotherRequest() async {
        let requests = PermissionRequests()
        let gate = RequestGate()
        #expect(requests.begin(.screenRecording, granted: false) { await gate.wait() })
        while await gate.count == 0 { await Task.yield() }
        // Simulates the menu and host RPC arriving while consent is unresolved.
        #expect(!requests.begin(.screenRecording, granted: false) { await gate.wait() })
        #expect(requests.active == .screenRecording)
        #expect(await gate.count == 1)
        #expect(requests.events.last?.stage == "request-coalesced")
        await gate.release()
        while requests.active != nil { await Task.yield() }
        // A denied request routes to Settings, never another system prompt/reset.
        #expect(!requests.begin(.screenRecording, granted: false) { await gate.wait() })
        #expect(await gate.count == 1)
    }

    @Test func repairRequiresExplicitCallAndCannotResetPendingConsent() async {
        let requests = PermissionRequests()
        let gate = RequestGate()
        requests.begin(.accessibility, granted: false) { await gate.wait() }
        while await gate.count == 0 { await Task.yield() }
        #expect(!(await requests.repair(.accessibility) { true }))
        await gate.release()
        while requests.active != nil { await Task.yield() }
        #expect(await requests.repair(.accessibility) { true })
        #expect(requests.begin(.accessibility, granted: false) { false })
        while requests.active != nil { await Task.yield() }
        #expect(requests.events.filter { $0.stage == "explicit-repair-started" }.count == 1)
    }

    @Test func grantedPermissionNeverLaunchesPromptAndEventsAreBounded() {
        let requests = PermissionRequests()
        for _ in 0..<100 {
            #expect(!requests.begin(.screenRecording, granted: true) { false })
        }
        #expect(requests.active == nil)
        #expect(requests.events.count == 64)
        #expect(requests.events.allSatisfy { $0.stage == "already-granted" })
    }

    @Test func anotherPermissionIsExplicitlyDeferredUntilTheFirstReturns() async {
        let requests = PermissionRequests()
        let gate = RequestGate()
        requests.begin(.accessibility, granted: false) { await gate.wait() }
        while await gate.count == 0 { await Task.yield() }
        #expect(!requests.begin(.screenRecording, granted: false) { false })
        #expect(requests.events.last?.stage == "request-deferred-other-permission")
        await gate.release()
        while requests.active != nil { await Task.yield() }
        #expect(requests.begin(.screenRecording, granted: false) { false })
        while requests.active != nil { await Task.yield() }
    }
}
#endif
