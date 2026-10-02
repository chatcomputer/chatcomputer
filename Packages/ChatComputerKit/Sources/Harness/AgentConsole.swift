#if os(macOS)
import BridgeProtocol
import Foundation
import GuestBridge

/// Like GuestConsole, but every action goes through the guest agent (the model's path), and
/// screenshots are the agent's own captures. Commands, one per line in <dir>/commands:
///     shot | click X Y [COUNT] | rclick X Y | move X Y | drag X1 Y1 X2 Y2 | scroll up|down N X Y
///     type TEXT | key COMBO | wait SECONDS | done
@MainActor
enum AgentConsole {
    static func serve(_ bridge: BridgeServer, vmID: UUID, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let commands = directory.appendingPathComponent("commands")
        if !FileManager.default.fileExists(atPath: commands.path) { try Data().write(to: commands) }
        let lease = UUID()
        func send(_ command: GuestCommand) async throws -> CommandResult {
            try await bridge.send(CommandEnvelope(vmID: vmID, jobID: nil, leaseToken: lease, observationVersion: nil,
                                                  deadline: Date().addingTimeInterval(60), command: command))
        }
        _ = try await send(.setLease(lease))
        VMProbe.log("agent console ready: \(commands.path)")
        var processed = 0, shots = 0
        while true {
            let lines = (try? String(contentsOf: commands, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
            while processed < lines.count - 1 {
                let line = lines[processed].trimmingCharacters(in: .whitespaces)
                processed += 1
                guard !line.isEmpty else { continue }
                if line == "done" { record(directory, "done"); _ = try? await send(.setLease(nil)); return }
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                let rest = parts.count > 1 ? parts[1] : ""
                let n = rest.split(separator: " ").compactMap { Int($0) }
                func point(_ i: Int) -> ScreenPoint { ScreenPoint(x: n[i], y: n[i + 1]) }
                do {
                    let result: CommandResult
                    switch parts[0] {
                    case "shot":
                        shots += 1
                        result = try await send(.screenshot(region: nil))
                        if case .screenshot(let shot) = result {
                            let name = String(format: "ashot-%03d.png", shots)
                            try shot.imageData.write(to: directory.appendingPathComponent(name))
                            record(directory, "shot → \(name) \(shot.width)x\(shot.height)")
                            continue
                        }
                    case "click": result = try await send(.perform(.click(button: .left, count: n.count > 2 ? n[2] : 1, at: point(0), modifiers: [])))
                    case "rclick": result = try await send(.perform(.click(button: .right, count: 1, at: point(0), modifiers: [])))
                    case "move": result = try await send(.perform(.mouseMove(to: point(0))))
                    case "drag": result = try await send(.perform(.drag(from: point(0), to: point(2), modifiers: [])))
                    case "scroll":
                        let words = rest.split(separator: " ").map(String.init)
                        let numbers = words.dropFirst().compactMap { Int($0) }
                        result = try await send(.perform(.scroll(direction: words.first == "up" ? .up : .down, amount: numbers.first ?? 3,
                                                                 at: numbers.count >= 3 ? ScreenPoint(x: numbers[1], y: numbers[2]) : nil, modifiers: [])))
                    case "type": result = try await send(.perform(.type(text: rest)))
                    case "key": result = try await send(.perform(.key(combo: rest, repeat: 1)))
                    case "wait": try await Task.sleep(for: .seconds(Double(rest) ?? 1)); result = .ok
                    default: result = .failure(BridgeError(.invalidCommand, "unknown command"))
                    }
                    record(directory, "\(line) → \(result)")
                } catch {
                    record(directory, "\(line) → ERROR \(error)")
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func record(_ directory: URL, _ text: String) {
        VMProbe.log("agent console: \(text)")
        let log = directory.appendingPathComponent("log")
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile(); handle.write(Data((text + "\n").utf8)); try? handle.close()
        } else {
            try? Data((text + "\n").utf8).write(to: log)
        }
    }
}
#endif
