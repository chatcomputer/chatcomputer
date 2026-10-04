import Foundation
import Testing
@testable import BridgeProtocol

@Suite struct GuestStatusTests {
    private func report(aqua: Bool = true, locked: Bool = false, ax: Bool = true, screen: Bool = true) -> HealthReport {
        HealthReport(agentVersion: "1.0.0 (7)", driver: "native", hasAquaSession: aqua, screenLocked: locked,
                     accessibilityGranted: ax, screenRecordingGranted: screen, sharedFoldersMounted: true)
    }

    @Test func readinessNamesTheFirstProblem() {
        #expect(GuestReadiness(connected: false, report: nil) == .agentNotConnected)
        #expect(GuestReadiness(connected: true, report: nil) == .agentNotAnswering)
        #expect(GuestReadiness(connected: true, report: report()) == .ready)
        #expect(GuestReadiness(connected: true, report: report()).problem == nil)
        #expect(GuestReadiness(connected: true, report: report(aqua: false, locked: true)) == .noDesktopSession)
        #expect(GuestReadiness(connected: true, report: report(locked: true)) == .screenLocked)
        let missing = GuestReadiness(connected: true, report: report(ax: false, screen: false))
        #expect(missing.problem == "the agent in the virtual Mac lacks Accessibility and Screen Recording permission")
        #expect(GuestReadiness(connected: true, report: report(screen: false)).problem?.hasSuffix("lacks Screen Recording permission") == true)
    }

    @Test func versionIncludesTheBuild() throws {
        #expect(AgentVersion.string(short: "1.0.0", build: "7") == "1.0.0 (7)")
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)/Agent.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "7"]
        info.write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true)
        #expect(AgentVersion.of(bundle: bundle) == "1.0.0 (7)")
        #expect(AgentVersion.of(bundle: bundle.deletingLastPathComponent()) == nil)
    }

    @Test func updatePolicyWaitsForIdleAndGivesUp() {
        var policy = AgentUpdatePolicy()
        let start = Date()
        #expect(!policy.shouldUpdate(running: "1.0.0 (7)", bundled: "1.0.0 (7)", busy: false, now: start))
        #expect(!policy.shouldUpdate(running: "0.2.0 (4)", bundled: "1.0.0 (7)", busy: true, now: start))
        #expect(policy.shouldUpdate(running: "0.2.0 (4)", bundled: "1.0.0 (7)", busy: false, now: start))
        // A newer agent in the guest (an older app) is replaced too.
        #expect(policy.shouldUpdate(running: "1.1.0 (9)", bundled: "1.0.0 (7)", busy: false, now: start))

        policy.began(at: start)
        policy.finished(succeeded: false)
        #expect(!policy.shouldUpdate(running: "0.2.0 (4)", bundled: "1.0.0 (7)", busy: false, now: start.addingTimeInterval(30)))
        var now = start.addingTimeInterval(61)
        #expect(policy.shouldUpdate(running: "0.2.0 (4)", bundled: "1.0.0 (7)", busy: false, now: now))
        for _ in 0..<2 {
            policy.began(at: now)
            policy.finished(succeeded: false)
            now = now.addingTimeInterval(61)
        }
        #expect(policy.failures == 3)
        #expect(!policy.shouldUpdate(running: "0.2.0 (4)", bundled: "1.0.0 (7)", busy: false, now: now))
    }
}
