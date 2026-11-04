#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import HostControl

@MainActor
@Suite struct TerminalBootstrapTests {
    @Test func bootstrapScriptParsesWithoutExecutingItsCommands() throws {
        let parser = Process()
        parser.executableURL = URL(fileURLWithPath: "/bin/sh")
        parser.arguments = ["-n", "-c", TerminalBootstrap.command(username: "agent", verificationID: "246824")]
        parser.standardOutput = FileHandle.nullDevice
        parser.standardError = FileHandle.nullDevice
        try parser.run()
        parser.waitUntilExit()
        #expect(parser.terminationStatus == 0)
    }

    func screen(_ lines: [String], terminal: Bool = true) -> ScreenText {
        let menu = terminal ? ["Terminal", "Shell"] : ["Finder", "Go"]
        return ScreenText(items: menu.enumerated().map {
            .init(text: $0.element, rect: CGRect(x: 50 + $0.offset * 70, y: 4, width: 60, height: 16))
        } + lines.enumerated().map {
            .init(text: $0.element, rect: CGRect(x: 100, y: 90 + $0.offset * 20, width: 180, height: 16))
        })
    }

    @Test func neverReadsOrTypesAPasswordBeforeTerminalAndItsPrompt() async {
        var passwordReads = 0
        var typed: [String] = []
        let flow = TerminalBootstrap(read: { screen([], terminal: false) }, key: { _ in },
                                     type: { typed.append($0) }, password: { passwordReads += 1; return "fixture-secret" },
                                     pause: { _ in await Task.yield() }, verificationID: "246824")
        await #expect(throws: HostControlError.self) { try await flow.run(username: "agent") }
        #expect(passwordReads == 0)
        #expect(typed == ["Terminal"])
    }

    @Test func waitsForEachRealPromptAndRequiresVerifiedCompletion() async throws {
        var frames = [screen([]), screen([TerminalBootstrap.shell + "_246824"]), screen([TerminalBootstrap.auth + "_246824"]), screen([TerminalBootstrap.auth + "_246824"]),
                      screen([TerminalBootstrap.auth + "_246824", TerminalBootstrap.accountAuth + "_246824", "Enter password for agent:"]), screen([TerminalBootstrap.ready + "_246824"])]
        var typed: [String] = []
        var reads = 0
        let flow = TerminalBootstrap(read: { frames.removeFirst() }, key: { _ in }, type: { typed.append($0) },
                                     password: { reads += 1; return "fixture-secret" }, pause: { _ in await Task.yield() }, verificationID: "246824")
        try await flow.run(username: "agent")
        #expect(reads == 2)
        #expect(typed.filter { $0 == "fixture-secret" }.count == 2)
        #expect(typed.last == "exit")
        #expect(!typed[1].contains("fixture-secret"))
        #expect(!typed[1].contains(TerminalBootstrap.ready))
    }

    @Test func failedServiceChecksNeverReportSuccess() async {
        var frames = [screen([]), screen([TerminalBootstrap.shell + "_246824"]), screen([TerminalBootstrap.failed + "_246824"])]
        var typed: [String] = []
        let flow = TerminalBootstrap(read: { frames.removeFirst() }, key: { _ in }, type: { typed.append($0) },
                                     password: { "fixture-secret" }, pause: { _ in await Task.yield() }, verificationID: "246824")
        await #expect(throws: HostControlError.self) { try await flow.run(username: "agent") }
        #expect(!typed.contains("exit"))
    }

    @Test func rejectedPasswordIsNotSentAgain() async {
        var frames = [screen([]), screen([TerminalBootstrap.shell + "_246824"]), screen([TerminalBootstrap.auth + "_246824"]), screen(["Sorry, try again.", "Password:"])]
        var reads = 0
        let flow = TerminalBootstrap(read: { frames.removeFirst() }, key: { _ in }, type: { _ in },
                                     password: { reads += 1; return "fixture-secret" }, pause: { _ in await Task.yield() }, verificationID: "246824")
        await #expect(throws: HostControlError.self) { try await flow.run(username: "agent") }
        #expect(reads == 1)
    }

    @Test func previousPasswordAndReadyLinesCannotAuthorizeThisAttempt() async {
        var reads = 0
        var typed: [String] = []
        let flow = TerminalBootstrap(read: { screen([TerminalBootstrap.shell + "_246824", "Password:", TerminalBootstrap.ready + "_111111"]) },
                                     key: { _ in }, type: { typed.append($0) },
                                     password: { reads += 1; return "fixture-secret" },
                                     pause: { _ in await Task.yield() }, verificationID: "246824")
        await #expect(throws: HostControlError.self) { try await flow.run(username: "agent") }
        #expect(reads == 0)
        #expect(!typed.contains("exit"))
    }

    @Test func echoingTheCommandIsNotAnAuthenticationPrompt() async {
        var reads = 0
        let command = TerminalBootstrap.command(username: "agent", verificationID: "246824")
        let flow = TerminalBootstrap(read: { screen([TerminalBootstrap.shell + "_246824", command]) }, key: { _ in }, type: { _ in },
                                     password: { reads += 1; return "fixture-secret" },
                                     pause: { _ in await Task.yield() }, verificationID: "246824")
        await #expect(throws: HostControlError.self) { try await flow.run(username: "agent") }
        #expect(reads == 0)
        #expect(!command.contains(TerminalBootstrap.auth))
        #expect(!command.contains(TerminalBootstrap.ready))
    }

    @Test func aPreviousAccountPasswordPromptCannotAuthorizeThisAttempt() async {
        var reads = 0
        let flow = TerminalBootstrap(read: { screen([TerminalBootstrap.shell + "_246824", "Enter password for agent:", TerminalBootstrap.ready + "_111111"]) },
                                     key: { _ in }, type: { _ in },
                                     password: { reads += 1; return "fixture-secret" },
                                     pause: { _ in await Task.yield() }, verificationID: "246824")
        await #expect(throws: HostControlError.self) { try await flow.run(username: "agent") }
        #expect(reads == 0)
    }

    @Test func existingTerminalDoesNotOpenSpotlightOverItsOwnMenu() async throws {
        var frames = [screen([]), screen([TerminalBootstrap.shell + "_246824"]),
                      screen([TerminalBootstrap.ready + "_246824"])]
        var keys: [String] = []
        let flow = TerminalBootstrap(read: { frames.removeFirst() }, key: { keys.append($0) },
                                     type: { _ in }, password: { "fixture-secret" },
                                     pause: { _ in await Task.yield() }, verificationID: "246824")
        try await flow.run(username: "agent")
        #expect(!keys.contains("cmd+space"))
        #expect(keys.first == "ctrl+c")
    }

    @Test func finderDesktopOpensTerminalBeforeSendingTheShellProbe() async throws {
        var frames = [screen([], terminal: false), screen([], terminal: false), screen([]),
                      screen([TerminalBootstrap.shell + "_246824"]), screen([TerminalBootstrap.ready + "_246824"])]
        var typed: [String] = []
        let flow = TerminalBootstrap(read: { frames.removeFirst() }, key: { _ in },
                                     type: { typed.append($0) }, password: { "fixture-secret" },
                                     pause: { _ in await Task.yield() }, verificationID: "246824")
        try await flow.run(username: "agent")
        #expect(typed.first == "Terminal")
        #expect(typed[1].hasPrefix("printf "))
        #expect(typed[2].hasPrefix("sudo "))
    }

    @Test func pendingOldSudoPreventsPrivilegedCommandAndPassword() async {
        var typed: [String] = []
        var reads = 0
        let flow = TerminalBootstrap(read: { screen([TerminalBootstrap.auth + "_111111"]) },
                                     key: { _ in }, type: { typed.append($0) },
                                     password: { reads += 1; return "fixture-secret" },
                                     pause: { _ in await Task.yield() }, verificationID: "246824")
        await #expect(throws: HostControlError.self) { try await flow.run(username: "agent") }
        #expect(reads == 0)
        #expect(!typed.contains(where: { $0.hasPrefix("sudo ") }))
        #expect(typed.count == 1)
        #expect(!typed[0].contains(TerminalBootstrap.shell))
    }

    @Test func waitsForFreshShellMarkerAfterInterrupt() async throws {
        var frames = [screen([]), screen([TerminalBootstrap.shell + "_111111"]),
                      screen([TerminalBootstrap.shell + "_246824"]),
                      screen([TerminalBootstrap.ready + "_246824"])]
        var shellObserved = false
        let flow = TerminalBootstrap(read: {
            let next = frames.removeFirst()
            if next.contains(TerminalBootstrap.shell + "_246824") { shellObserved = true }
            return next
        }, key: { _ in }, type: { text in
            if text.hasPrefix("sudo ") { #expect(shellObserved) }
        }, password: { Issue.record("No password prompt was shown"); return "fixture-secret" },
        pause: { _ in await Task.yield() }, verificationID: "246824")
        try await flow.run(username: "agent")
    }

    @Test func freshAccountMarkerSupportsAnAlreadyAuthorizedRootCommand() async throws {
        var frames = [screen([]), screen([TerminalBootstrap.shell + "_246824"]),
                      screen([TerminalBootstrap.accountAuth + "_246824", "Enter password for agent:"]),
                      screen([TerminalBootstrap.ready + "_246824"])]
        var reads = 0
        let flow = TerminalBootstrap(read: { frames.removeFirst() }, key: { _ in }, type: { _ in },
                                     password: { reads += 1; return "fixture-secret" },
                                     pause: { _ in await Task.yield() }, verificationID: "246824")
        try await flow.run(username: "agent")
        #expect(reads == 1)
    }
}
#endif
