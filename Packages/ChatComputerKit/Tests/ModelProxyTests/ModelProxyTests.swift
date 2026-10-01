import Foundation
import Testing
import BridgeProtocol
@testable import ModelProxy

@Suite struct ComputerToolsetTests {
    @Test func mapsMemberToolsToGuestCommands() throws {
        #expect(try ComputerToolset.command(name: "screenshot", input: [:]) == .screenshot(region: nil))
        #expect(try ComputerToolset.command(name: "zoom", input: ["region": [0, 0, 100, 50]])
            == .screenshot(region: ScreenRect(x0: 0, y0: 0, x1: 100, y1: 50)))
        #expect(try ComputerToolset.command(name: "left_click", input: ["coordinate": [512, 742], "text": "cmd+shift"])
            == .perform(.click(button: .left, count: 1, at: ScreenPoint(x: 512, y: 742), modifiers: ["cmd", "shift"])))
        #expect(try ComputerToolset.command(name: "triple_click", input: [:])
            == .perform(.click(button: .left, count: 3, at: nil, modifiers: [])))
        #expect(try ComputerToolset.command(name: "key", input: ["text": "cmd+s", "repeat": 500])
            == .perform(.key(combo: "cmd+s", repeat: 100)))
        #expect(try ComputerToolset.command(name: "scroll", input: ["scroll_direction": "down", "scroll_amount": 5])
            == .perform(.scroll(direction: .down, amount: 5, at: nil, modifiers: [])))
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: ComputerToolset.InvalidInput.self) {
            try ComputerToolset.command(name: "left_click_drag", input: ["coordinate": [1, 2]])
        }
        #expect(throws: ComputerToolset.InvalidInput.self) {
            try ComputerToolset.command(name: "launch_rocket", input: [:])
        }
    }

    @Test func everyResultEchoesToolsetName() {
        let text = ComputerToolset.textResult(toolUseID: "t1", "OK")
        let skipped = ComputerToolset.notExecuted(toolUseID: "t2")
        #expect(text["toolset_name"] == "computer")
        #expect(skipped["toolset_name"] == "computer")
        #expect(skipped["is_error"] == true)
    }

    @Test func screenshotScaleRespectsLimits() {
        #expect(ScreenshotLimits.scale(width: 1280, height: 800) == 1)
        let scale = ScreenshotLimits.scale(width: 5120, height: 2880)
        #expect(Double(5120) * scale <= Double(ScreenshotLimits.maxLongEdge))
    }
}

@Suite struct AnthropicClientTests {
    @Test func buildsToolsetRequestWithoutLegacyComputerTool() throws {
        let client = AnthropicClient { "sk-test" }
        let request = try client.makeRequest(system: "sys", tools: [ComputerToolset.definition], messages: [["role": "user", "content": "hi"]])
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["tools"]?.arrayValue?.first?["type"] == "computer_toolset_20260801")
        #expect(body["thinking"]?["type"] == "adaptive")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    }

    @Test func missingKeyFailsBeforeAnyNetworkCall() {
        let client = AnthropicClient { nil }
        #expect(throws: ModelError.missingAPIKey) { try client.makeRequest(system: "", tools: [], messages: []) }
    }

    @Test func classifiesErrors() {
        #expect(throws: ModelError.rateLimited(retryAfter: 7)) {
            try AnthropicClient.parse(status: 429, retryAfter: "7", body: Data())
        }
        let refusal = Data(#"{"content":[],"stop_reason":"refusal","stop_details":{"category":"cyber"}}"#.utf8)
        #expect(throws: ModelError.refused(category: "cyber")) {
            try AnthropicClient.parse(status: 200, retryAfter: nil, body: refusal)
        }
    }

    @Test func parsesToolsetToolUse() throws {
        let body = Data(#"""
        {"model":"claude-opus-5-5","stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5},
         "content":[{"type":"tool_use","id":"toolu_1","name":"left_click","toolset_name":"computer","input":{"coordinate":[1,2]}}]}
        """#.utf8)
        let response = try AnthropicClient.parse(status: 200, retryAfter: nil, body: body)
        #expect(response.blocks == [.toolUse(id: "toolu_1", name: "left_click", toolsetName: "computer", input: ["coordinate": [1, 2]])])
        #expect(response.inputTokens == 10)
    }
}

@Suite struct CompatibleDialectTests {
    let client = AnthropicClient(configuration: .init(model: "deepseek-chat", dialect: .compatible(displayWidth: 1280, displayHeight: 800))) { "sk-test" }

    @Test func replacesToolsetAndDropsClaudeOnlyFields() throws {
        let request = try client.makeRequest(system: "sys", tools: [ComputerToolset.definition] + HostTools.definitions, messages: [["role": "user", "content": "hi"]])
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
        let tools = body["tools"]?.arrayValue ?? []
        #expect(tools.first?["name"] == "computer")
        #expect(tools.first?["type"] == nil)
        #expect(tools.count == 1 + HostTools.definitions.count)
        #expect(body["thinking"] == nil)
        #expect(body["fallbacks"] == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func historyAndResponsesRoundTripThroughToolsetShape() throws {
        // Response: the custom tool comes back as a toolset member.
        let wire: [JSONValue] = [["type": "tool_use", "id": "t1", "name": "computer", "input": ["action": "left_click", "coordinate": [10, 20]]]]
        let local = CompatibleDialect.responseContent(wire)
        #expect(local[0]["name"] == "left_click")
        #expect(local[0]["toolset_name"] == "computer")
        #expect(local[0]["input"] == ["coordinate": [10, 20]])
        // History: the same block goes back out in wire shape, and results lose toolset_name.
        let history: [JSONValue] = [
            ["role": "assistant", "content": .array(local)],
            ["role": "user", "content": [ComputerToolset.textResult(toolUseID: "t1", "OK")]],
        ]
        let outgoing = CompatibleDialect.requestMessages(history)
        #expect(outgoing[0]["content"]?.arrayValue?[0] == wire[0])
        #expect(outgoing[1]["content"]?.arrayValue?[0]["toolset_name"] == nil)
        // Host tools pass through untouched.
        let report: JSONValue = ["type": "tool_use", "id": "t2", "name": "report_result", "input": [:]]
        #expect(CompatibleDialect.responseContent([report]) == [report])
    }
}
