import BridgeProtocol
import Foundation
import ModelProxy
import Testing
@testable import ComputerControl

@Suite struct ControlCommandTests {
    private func request(_ arguments: [String]) throws -> ControlCommand {
        guard case .request(let command, let json, _) = try ControlCLI.parse(arguments) else {
            throw ControlError.usage("not a request")
        }
        return try ControlCommand(name: command, arguments: json)
    }

    @Test func commandLineAndMCPShareOneVocabulary() throws {
        #expect(try request(["click", "640", "400"]) == .click(at: ScreenPoint(x: 640, y: 400), button: .left, count: 1, modifiers: []))
        #expect(try request(["click", "--double", "--mods", "cmd,shift", "10", "20", "--right"])
                == .click(at: ScreenPoint(x: 10, y: 20), button: .right, count: 2, modifiers: ["cmd", "shift"]))
        #expect(try request(["type", "hello", "world"]) == .type(text: "hello world"))
        #expect(try request(["key", "cmd+s", "--repeat", "2"]) == .key(combo: "cmd+s", repeat: 2))
        #expect(try request(["scroll", "100", "200", "down"]) == .scroll(at: ScreenPoint(x: 100, y: 200), direction: .down, amount: 3))
        #expect(try request(["drag", "1", "2", "3", "4"]) == .drag(from: ScreenPoint(x: 1, y: 2), to: ScreenPoint(x: 3, y: 4)))
        #expect(try request(["screenshot", "0", "0", "640", "400"]) == .screenshot(region: ScreenRect(x0: 0, y0: 0, x1: 640, y1: 400)))
        #expect(try request(["snapshot", "restore", "Before", "update", "--no-save"]) == .snapshotRestore(snapshot: "Before update", saveCurrent: false))
        #expect(try request(["snapshot", "take"]) == .snapshotTake(name: nil))
        #expect(try request(["snapshot", "delete", "Before", "regression"]) == .snapshotDelete(snapshot: "Before regression"))
        #expect(try request(["wait", "1.5"]) == .wait(seconds: 1.5))

        // The same command as an MCP client sends it.
        #expect(try ControlCommand(name: "click", arguments: ["x": 640, "y": 400, "count": 2])
                == .click(at: ScreenPoint(x: 640, y: 400), button: .left, count: 2, modifiers: []))
        #expect(try ControlCommand(name: "snapshot_restore", arguments: ["snapshot": "A"]) == .snapshotRestore(snapshot: "A", saveCurrent: true))
    }

    @Test func commandLineAndMCPListTheSameCommands() throws {
        let reached = Set(ControlCLI.toolsByCommand.values.flatMap { $0 })
        #expect(reached == Set(ControlTool.all.map(\.name)))
        // Every command line command appears in the usage text.
        for command in ControlCLI.toolsByCommand.keys {
            #expect(ControlGuide.commandLineUsage.contains("  \(command)"), "\(command) is missing from the usage text")
        }
    }

    @Test func shareCommands() throws {
        #expect(try request(["share", "list"]) == .shareList)
        #expect(try request(["share", "add", "/tmp/site", "--writable"]) == .shareAdd(path: "/tmp/site", writable: true))
        #expect(try request(["share", "add", "/tmp/site"]) == .shareAdd(path: "/tmp/site", writable: false))
        #expect(try request(["share", "remove", "site", "2"]) == .shareRemove(name: "site 2"))
        #expect(throws: ControlError.self) { try ControlCLI.parse(["share", "delete", "x"]) }
    }

    @Test func screenshotKeepsItsOutputPath() throws {
        #expect(try ControlCLI.parse(["screenshot", "--out", "/tmp/a.png"]) == .request(command: "screenshot", arguments: [:], screenshotPath: "/tmp/a.png"))
        #expect(try ControlCLI.parse([]) == .help)
        #expect(try ControlCLI.parse(["mcp"]) == .mcp)
    }

    @Test func badInputIsRejectedWithUsage() {
        #expect(throws: ControlError.self) { try ControlCLI.parse(["click", "10"]) }
        #expect(throws: ControlError.self) { try ControlCLI.parse(["click", "ten", "20"]) }
        #expect(throws: ControlError.self) { try ControlCLI.parse(["status", "extra"]) }
        #expect(throws: ControlError.unknownCommand("fly")) { try ControlCLI.parse(["fly"]) }
        #expect(throws: ControlError.self) { try ControlCommand(name: "scroll", arguments: ["x": 1, "y": 1, "direction": "sideways"]) }
        #expect(throws: ControlError.self) { try ControlCommand(name: "wait", arguments: ["seconds": 600]) }
        #expect(throws: ControlError.self) { try ControlCommand(name: "screenshot", arguments: ["region": [10, 10, 5, 20]]) }
    }

    @Test func onlyInputCommandsNeedTheLease() throws {
        #expect(try request(["click", "1", "2"]).action != nil)
        #expect(try request(["type", "x"]).action != nil)
        #expect(try request(["screenshot"]).action == nil)
        #expect(try request(["wait", "1"]).action == nil)
        #expect(try request(["snapshot", "list"]).action == nil)
    }

    @Test func clientNameComesFromTheAgentsEnvironment() {
        #expect(ControlCLI.clientName(environment: ["CLAUDECODE": "1"]) == "Claude Code")
        #expect(ControlCLI.clientName(environment: ["CODEX_SANDBOX": "seatbelt"]) == "Codex")
        #expect(ControlCLI.clientName(environment: ["CHATCOMPUTER_CLIENT": "My bot", "CLAUDECODE": "1"]) == "My bot")
        #expect(ControlCLI.clientName(environment: [:]) == "Command line")
    }

    @Test func everyListedToolParses() {
        for tool in ControlTool.all {
            #expect(throws: Never.self) {
                // Required arguments filled with plausible values must parse.
                var arguments: [String: JSONValue] = [:]
                for case .string(let key) in tool.inputSchema["required"]?.arrayValue ?? [] {
                    arguments[key] = ["direction": "down", "text": "a", "combo": "Return", "snapshot": "A", "path": "/tmp/a", "name": "site"][key] ?? 1
                }
                _ = try ControlCommand(name: tool.name, arguments: arguments)
            }
        }
    }
}

@Suite struct MCPSessionTests {
    private func call(_ session: MCPSession, _ message: String) async throws -> JSONValue? {
        guard let reply = await session.handle(Data(message.utf8)) else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: reply)
    }

    @Test func handshakeListAndCall() async throws {
        let seen = Recorder()
        let session = MCPSession(serverVersion: "9.9") { request in
            await seen.add(request)
            return request.command == "screenshot"
                ? ControlResponse(text: "1280×800", image: Data([1, 2, 3]), imageType: "image/png")
                : ControlResponse.error("The user has taken control.")
        }

        let initialized = try await call(session, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","version":"2"}}}"#)
        #expect(initialized?["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(initialized?["result"]?["serverInfo"]?["version"]?.stringValue == "9.9")
        #expect(try await call(session, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let list = try await call(session, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(list?["result"]?["tools"]?.arrayValue?.count == ControlTool.all.count)

        let shot = try await call(session, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}"#)
        let content = shot?["result"]?["content"]?.arrayValue
        #expect(content?.first?["type"]?.stringValue == "image")
        #expect(content?.first?["data"]?.stringValue == Data([1, 2, 3]).base64EncodedString())
        #expect(shot?["result"]?["isError"] == .bool(false))

        let click = try await call(session, #"{"jsonrpc":"2.0","id":"c","method":"tools/call","params":{"name":"click","arguments":{"x":1,"y":2}}}"#)
        #expect(click?["id"]?.stringValue == "c")
        #expect(click?["result"]?["isError"] == .bool(true))
        #expect(await seen.requests.map(\.client) == ["Claude Code", "Claude Code"])
        #expect(await seen.requests.last?.arguments["x"] == 1)
    }

    @Test func protocolErrors() async throws {
        let session = MCPSession(serverVersion: "1") { _ in ControlResponse(text: "") }
        #expect(try await call(session, "not json")?["error"]?["code"] == -32700)
        #expect(try await call(session, #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)?["error"]?["code"] == -32601)
        #expect(try await call(session, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"format_disk"}}"#)?["error"]?["code"] == -32602)
        #expect(try await call(session, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)?["result"] == [:])
    }

    private actor Recorder {
        var requests: [ControlRequest] = []
        func add(_ request: ControlRequest) { requests.append(request) }
    }
}

#if os(macOS)
@Suite struct ControlSocketTests {
    @Test func requestAndResponseCrossTheSocket() async throws {
        let path = "/tmp/cc-test-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(path: path) { request in
            ControlResponse(text: "\(request.client): \(request.command)", image: request.command == "screenshot" ? Data(repeating: 7, count: 300_000) : nil)
        }
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let response = try await Task.detached { try ControlClient.send(ControlRequest(command: "status", client: "Tester"), path: path) }.value
        #expect(response.text == "Tester: status")
        // A screenshot-sized answer arrives whole.
        let shot = try await Task.detached { try ControlClient.send(ControlRequest(command: "screenshot", client: "Tester"), path: path) }.value
        #expect(shot.image?.count == 300_000)
    }

    @Test func aSecondServerNeverTakesALiveSocket() throws {
        let path = "/tmp/cc-test-\(UUID().uuidString.prefix(8)).sock"
        let first = ControlServer(path: path) { _ in ControlResponse(text: "first") }
        try first.start()
        defer { first.stop() }
        #expect(throws: SocketError.self) { try ControlServer(path: path) { _ in ControlResponse(text: "second") }.start() }
        #expect(try ControlClient.send(ControlRequest(command: "status", client: "x"), path: path).text == "first")
    }

    @Test func noAppMeansNotRunning() {
        #expect(throws: ControlClient.NotRunning.self) {
            try ControlClient.send(ControlRequest(command: "status", client: "x"), path: "/tmp/cc-missing-\(UUID().uuidString.prefix(8)).sock")
        }
    }

    @Test func commandLineModeIsChosenByArguments() {
        #expect(ControlCommandLine.isCommandLine(["/Applications/ChatComputer.app/Contents/MacOS/ChatComputer", "status"]))
        #expect(ControlCommandLine.isCommandLine(["/usr/local/bin/chatcomputer"]))
        #expect(!ControlCommandLine.isCommandLine(["/Applications/ChatComputer.app/Contents/MacOS/ChatComputer"]))
        #expect(ControlCommandLine.isCommandLine(["/Applications/ChatComputer.app/Contents/MacOS/ChatComputer", "fly"]))
        #expect(ControlCommandLine.isCommandLine(["/Applications/ChatComputer.app/Contents/MacOS/ChatComputer", "--help"]))
        #expect(!ControlCommandLine.isCommandLine(["/Applications/ChatComputer.app/Contents/MacOS/ChatComputer", "-NSDocumentRevisionsDebugMode", "YES"]))
    }
}
#endif
