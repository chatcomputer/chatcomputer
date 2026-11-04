import Foundation
import Testing
@testable import BridgeProtocol

@Suite struct FrameCodecTests {
    @Test func roundTripsFramesSplitAcrossReads() throws {
        let envelope = CommandEnvelope(
            vmID: UUID(), jobID: UUID(), leaseToken: UUID(), observationVersion: 3,
            deadline: Date(timeIntervalSince1970: 1_800_000_000),
            command: .perform(.click(button: .left, count: 2, at: ScreenPoint(x: 10, y: 20), modifiers: ["cmd"]))
        )
        let first = try FrameEncoder().encode(HostMessage.command(envelope))
        let second = try FrameEncoder().encode(HostMessage.command(envelope))
        let stream = first + second

        var decoder = FrameDecoder()
        var decoded: [HostMessage] = []
        // Feed one byte at a time to exercise partial reads.
        for byte in stream {
            decoder.append(Data([byte]))
            while let message = try decoder.next(HostMessage.self) {
                decoded.append(message)
            }
        }
        #expect(decoded == [.command(envelope), .command(envelope)])
    }

    @Test func rejectsOversizedFrames() throws {
        var decoder = FrameDecoder()
        var length = UInt32(Bridge.maxFrameBytes + 1).bigEndian
        decoder.append(Data(bytes: &length, count: 4))
        #expect(throws: FrameError.frameTooLarge(Bridge.maxFrameBytes + 1)) {
            _ = try decoder.next(GuestMessage.self)
        }
    }

    @Test func onlyInputCommandsNeedTheLease() {
        #expect(GuestCommand.perform(.type(text: "hi")).requiresLease)
        #expect(!GuestCommand.screenshot(region: nil).requiresLease)
        #expect(!GuestCommand.health.requiresLease)
    }

    @Test func desktopReadinessNeedsMoreThanAConnection() {
        var report = HealthReport(agentVersion: "1", driver: "native", hasAquaSession: true, screenLocked: false,
                                  accessibilityGranted: true, screenRecordingGranted: true, sharedFoldersMounted: true)
        #expect(report.isDesktopReady)
        report.screenLocked = true
        #expect(!report.isDesktopReady)
    }

    @Test func oldGuestCapabilitiesAndHealthStillDecode() throws {
        let oldCapabilities = Data(#"{"driver":"native","driverVersion":"0.9.11 (43)","supportsAccessibilityTree":true,"supportsBrowserSnapshot":false,"supportsBackgroundInput":false}"#.utf8)
        let capabilities = try JSONDecoder().decode(DriverCapabilities.self, from: oldCapabilities)
        #expect(capabilities.supportsPermissionFlow == nil)
        let oldHealth = Data(#"{"agentVersion":"0.9.11 (43)","driver":"native","hasAquaSession":true,"screenLocked":false,"accessibilityGranted":true,"screenRecordingGranted":true,"sharedFoldersMounted":true}"#.utf8)
        let report = try JSONDecoder().decode(HealthReport.self, from: oldHealth)
        #expect(report.permissionDiagnostics == nil)
        #expect(report.isDesktopReady)
    }

    @Test func newSetupCommandsRoundTripWithoutRequiringInputLease() throws {
        for command in [GuestCommand.openPermissionSettings(.screenRecording), .captureProbe("CC CAPTURE 123456"), .captureProbe(nil)] {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(GuestCommand.self, from: data) == command)
            #expect(!command.requiresLease)
        }
    }
}
