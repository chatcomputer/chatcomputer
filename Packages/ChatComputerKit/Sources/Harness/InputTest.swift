#if os(macOS)
import BridgeProtocol
import Foundation
import GuestBridge

/// Driver reliability check without a model: a fixed script of shortcuts, typing and a save dialog,
/// sent to the guest agent like model actions, then a byte-for-byte check of the saved file.
@MainActor
enum InputTest {
    /// Upper and lower case, digits, every shifted and unshifted US symbol, and spaces.
    static let sample = #"The Quick Brown Fox 0123456789 ~!@#$%^&*()_+ `-=[]\;',./ {}|:"<>? End"#

    static func run(_ bridge: BridgeServer, vmID: UUID, outbox: URL, rounds: Int) async throws {
        let shots = outbox.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("input-test-shots")
        try? FileManager.default.removeItem(at: shots)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let lease = UUID()
        func send(_ command: GuestCommand, timeout: TimeInterval = 30) async throws -> CommandResult {
            try await bridge.send(CommandEnvelope(vmID: vmID, jobID: nil, leaseToken: lease, observationVersion: nil,
                                                  deadline: Date().addingTimeInterval(timeout), command: command))
        }
        func act(_ action: ComputerAction) async throws {
            let result = try await send(.perform(action))
            guard result == .ok else { throw ProbeError("\(action) → \(result)") }
        }
        func key(_ combo: String) async throws { try await act(.key(combo: combo, repeat: 1)) }
        func type(_ text: String) async throws { try await act(.type(text: text)) }
        func wait(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
        func snap(_ label: String) async {
            if case .screenshot(let shot)? = try? await send(.screenshot(region: nil)) {
                try? shot.imageData.write(to: shots.appendingPathComponent("\(label).png"))
            }
        }

        _ = try await send(.setLease(lease))
        var passed = 0
        for round in 1...rounds {
            let name = "input-test-\(round).txt"
            let file = outbox.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: file)
            let started = Date()
            do {
                // Open TextEdit with Spotlight, new plain-text document.
                try await key("cmd+space"); try await wait(1.2)
                try await type("TextEdit"); try await wait(1.0)
                try await key("return"); try await wait(2.5)
                try await key("cmd+n"); try await wait(1.5)
                try await key("cmd+shift+t"); try await wait(1.0)   // Format › Make Plain Text
                try await type(sample); try await wait(0.5)
                await snap("r\(round)-1-typed")
                // Save into the shared outbox through the save dialog (an out-of-process panel).
                try await key("cmd+s"); try await wait(1.5)
                try await key("cmd+a")
                try await type(name); try await wait(0.5)
                await snap("r\(round)-2-named")
                try await key("cmd+shift+g"); try await wait(1.2)
                try await type("/Volumes/My Shared Files/outbox/"); try await wait(0.8)
                await snap("r\(round)-3-path")
                try await key("return"); try await wait(1.5)
                try await key("return"); try await wait(2.0)
                // Close the document so the next round starts clean.
                try await key("cmd+w"); try await wait(1.0)
            } catch {
                VMProbe.log("round \(round): action failed: \(error)")
            }

            let saved = try? String(contentsOf: file, encoding: .utf8)
            let ok = saved?.trimmingCharacters(in: .newlines) == sample
            if ok { passed += 1 }
            VMProbe.log("round \(round): \(ok ? "PASS" : "FAIL") in \(VMProbe.elapsed(since: started))"
                        + (ok ? "" : "\n    expected: \(sample)\n    saved:    \(saved ?? "<no file at \(file.path)>")"))
            if !ok {
                await snap("r\(round)-4-after")
                // Leave no dialog or document behind for the next round.
                try? await key("escape"); try? await wait(0.5)
                try? await key("cmd+w"); try? await wait(0.8)
                try? await key("cmd+d"); try? await wait(0.8)   // "Delete" in the don't-save sheet
            }
        }
        _ = try? await send(.setLease(nil))
        VMProbe.log("input test: \(passed)/\(rounds) passed")
        guard passed == rounds else { throw ProbeError("input test: \(passed)/\(rounds) passed") }
    }
}
#endif
