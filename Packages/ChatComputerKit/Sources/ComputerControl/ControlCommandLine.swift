#if os(macOS)
import Foundation
import ModelProxy

/// `chatcomputer …`: the app's executable run from a terminal or by a coding agent.
///
/// It talks to the running app over the control socket, starting the app if needed.
public enum ControlCommandLine {
    public static let appBundleID = "app.chatcomputer.ChatComputer"

    /// Whether these process arguments ask for the command-line tool rather than the app's window.
    public static func isCommandLine(_ arguments: [String]) -> Bool {
        // The installed symlink is lowercase; the app's own executable is "ChatComputer", which must open the window.
        if arguments.first.map({ ($0 as NSString).lastPathComponent }) == "chatcomputer" { return true }
        // Anything that isn't a system flag (Xcode and AppKit pass "-NSSomething") is a command, even a mistyped
        // one: it must print an error, never open a second window.
        guard arguments.count > 1 else { return false }
        return ControlCLI.commands.contains(arguments[1]) || !arguments[1].hasPrefix("-")
    }

    public static func run(_ arguments: [String], version: String) async -> Int32 {
        let client = ControlCLI.clientName(environment: ProcessInfo.processInfo.environment)
        let invocation: ControlCLI.Invocation
        do {
            invocation = try ControlCLI.parse(Array(arguments.dropFirst()))
        } catch {
            printError("\(error)")
            return 2
        }
        switch invocation {
        case .help:
            print(ControlGuide.commandLineUsage + "\n\n" + ControlGuide.text)
            return 0
        case .mcp:
            await serveMCP(version: version)
            return 0
        case .request(let command, let arguments, let screenshotPath):
            let response = await send(ControlRequest(command: command, arguments: arguments, client: client))
            var text = response.text
            if let image = response.image {
                let url = screenshotPath.map { URL(fileURLWithPath: $0) } ?? screenshotFile(type: response.imageType)
                do {
                    try image.write(to: url)
                    text = "Saved screenshot to \(url.path)\n" + text
                } catch {
                    printError("Could not save the screenshot: \(error.localizedDescription)")
                    return 1
                }
            }
            if response.isError {
                printError(text)
                return 1
            }
            print(text)
            return 0
        }
    }

    /// Sends a request, starting Chat Computer first if it isn't running.
    static func send(_ request: ControlRequest) async -> ControlResponse {
        do {
            return try ControlClient.send(request)
        } catch is ControlClient.NotRunning {
            printError("Starting Chat Computer…")
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // Start the app this command belongs to (the symlink's target), not whichever copy Launch Services
            // finds first for the bundle ID: two copies must never run the same virtual Mac.
            open.arguments = ["-g"] + (ownAppBundle().map { [$0.path] } ?? ["-b", appBundleID])
            do {
                try open.run()
                open.waitUntilExit()
            } catch {
                return .error("Chat Computer is not running and could not be started: \(error.localizedDescription)")
            }
            guard open.terminationStatus == 0 else {
                return .error("Chat Computer is not running and could not be started. Is it installed in Applications?")
            }
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                if let response = try? ControlClient.send(request) { return response }
            }
            return .error("Chat Computer started but did not answer. Check the app's window.")
        } catch {
            return .error("Could not reach Chat Computer: \(error)")
        }
    }

    /// The .app this executable lives in, following the `chatcomputer` symlink.
    static func ownAppBundle() -> URL? {
        guard let path = CommandLine.arguments.first else { return nil }
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle : nil
    }

    private static func serveMCP(version: String) async {
        let session = MCPSession(serverVersion: version) { request in await send(request) }
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !line.isEmpty, let reply = await session.handle(Data(line.utf8)) else { continue }
                FileHandle.standardOutput.write(reply + Data([10]))
            }
        } catch {
            printError("mcp: \(error)")
        }
    }

    private static func screenshotFile(type: String?) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chatcomputer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        return directory.appendingPathComponent("screen-\(stamp)-\(Int.random(in: 100...999)).\(type == "image/jpeg" ? "jpg" : "png")")
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
#endif
