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

@Suite struct OpenAICompatibleClientTests {
    let client = OpenAICompatibleClient(configuration: .init(model: "gpt-test", baseURL: URL(string: "https://example.com/v1")!)) { "sk-test" }

    @Test func buildsChatCompletionsRequest() throws {
        let request = try client.makeRequest(system: "sys", tools: [ComputerToolset.definition] + HostTools.definitions,
                                             messages: [["role": "user", "content": "hi"]])
        #expect(request.url?.absoluteString == "https://example.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-test")
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
        let messages = body["messages"]?.arrayValue ?? []
        #expect(messages.first == ["role": "system", "content": "sys"])
        #expect(messages.last == ["role": "user", "content": "hi"])
        let names = body["tools"]?.arrayValue?.compactMap { $0["function"]?["name"]?.stringValue }
        #expect(names == ["computer", "report_result", "ask_user"])
        #expect(body["max_tokens"] != nil)
    }

    @Test func toolTurnsTranslateBothWays() throws {
        // Response: a tool call on the `computer` function comes back as a toolset member.
        let response = """
            {"model":"m","choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":"Clicking.",
            "reasoning_content":"secret","tool_calls":[{"id":"c1","type":"function","function":{"name":"computer",
            "arguments":"{\\"action\\":\\"left_click\\",\\"coordinate\\":[10,20]}"}}]}}],"usage":{"prompt_tokens":7,"completion_tokens":3}}
            """
        let parsed = try OpenAICompatibleClient.parse(status: 200, retryAfter: nil, body: Data(response.utf8))
        #expect(parsed.stopReason == "tool_use")
        #expect(parsed.inputTokens == 7)
        #expect(parsed.content.count == 3)   // reasoning, text, tool call
        #expect(parsed.content[2]["name"] == "left_click")
        #expect(parsed.content[2]["toolset_name"] == "computer")

        // History: the call goes back as tool_calls, its result as a tool message, the screenshot as a user image.
        let screenshot = ComputerToolset.imageResult(toolUseID: "c1", screenshot: .init(
            imageData: Data([1, 2, 3]), mediaType: "image/png", width: 1, height: 1, capturedAt: Date(), observationVersion: 1))
        let history: [JSONValue] = [
            ["role": "user", "content": "goal"],
            ["role": "assistant", "content": .array(parsed.content)],
            ["role": "user", "content": [screenshot]],
        ]
        let chat = OpenAICompatibleClient.chatMessages(system: "s", messages: history)
        #expect(chat.count == 5)   // system, user, assistant, tool, user(image)
        let assistant = chat[2]
        #expect(assistant["content"] == "Clicking.")
        #expect(assistant["reasoning_content"] == "secret")
        let call = assistant["tool_calls"]?.arrayValue?.first
        #expect(call?["function"]?["name"] == "computer")
        let arguments = try JSONDecoder().decode(JSONValue.self, from: Data((call?["function"]?["arguments"]?.stringValue ?? "{}").utf8))
        #expect(arguments["action"] == "left_click")
        #expect(chat[3]["role"] == "tool")
        #expect(chat[3]["tool_call_id"] == "c1")
        let image = chat[4]["content"]?.arrayValue?.first { $0["type"] == "image_url" }
        #expect(image?["image_url"]?["url"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func errorsMapToModelErrors() {
        #expect(throws: ModelError.authentication("bad key")) {
            try OpenAICompatibleClient.parse(status: 401, retryAfter: nil, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }
    }
}

@Suite struct VendorEchoAndTrimmingTests {
    @Test func reasoningAndExtraContentAreEchoedUnchanged() throws {
        let response = """
            {"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"reasoning_content":"think",
            "tool_calls":[{"id":"c1","type":"function","extra_content":{"google":{"thought_signature":"sig"}},
            "function":{"name":"report_result","arguments":"{}"}}]}}]}
            """
        let parsed = try OpenAICompatibleClient.parse(status: 200, retryAfter: nil, body: Data(response.utf8))
        let chat = OpenAICompatibleClient.chatMessages(system: "s", messages: [["role": "assistant", "content": .array(parsed.content)]])
        let assistant = chat[1]
        #expect(assistant["reasoning_content"] == "think")
        #expect(assistant["tool_calls"]?.arrayValue?.first?["extra_content"]?["google"]?["thought_signature"] == "sig")
        // Nothing is invented for vendors that did not send these fields.
        let plain = OpenAICompatibleClient.chatMessages(system: "s", messages: [["role": "assistant", "content": [["type": "text", "text": "hi"]]]])
        #expect(plain[1]["reasoning_content"] == nil)
    }

    @Test func onlyTheNewestScreenshotsAreKept() {
        func shot(_ id: String) -> JSONValue {
            ComputerToolset.imageResult(toolUseID: id, screenshot: .init(imageData: Data([1]), mediaType: "image/png", width: 1, height: 1,
                                                                        capturedAt: Date(), observationVersion: 1))
        }
        let history: [JSONValue] = (1...5).map { ["role": "user", "content": [shot("t\($0)")]] }
        let trimmed = CompatibleDialect.keepingRecentImages(history, limit: 3)
        let kinds = trimmed.map { $0["content"]?.arrayValue?.first?["content"]?.arrayValue?.first?["type"]?.stringValue }
        #expect(kinds == ["text", "text", "image", "image", "image"])
    }
}

@Suite struct ModelCatalogTests {
    @Test func tenVendorsWithThreeModelsEach() {
        let vendors = ModelCatalog.providers.filter { $0.id != "custom" }
        #expect(vendors.count == 10)
        #expect(vendors.contains { $0.id == "deepseek" })
        for vendor in vendors {
            #expect(vendor.models.count >= 3, "\(vendor.name)")
            #expect(!vendor.protocols.isEmpty, "\(vendor.name)")
            for (_, base) in vendor.endpoints { #expect(URL(string: base)?.scheme == "https", "\(vendor.name)") }
        }
        #expect(Set(ModelCatalog.providers.map(\.id)).count == ModelCatalog.providers.count)
    }

    @Test func settingsBuildTheRightClient() throws {
        let deepseek = try #require(ModelCatalog.provider("deepseek"))
        var settings = ModelSettings.preset(deepseek)
        #expect(settings.protocolKind == .openAI)
        #expect(try settings.makeClient { "k" } is OpenAICompatibleClient)
        settings.protocolKind = .anthropic
        settings.baseURL = deepseek.endpoints[.anthropic]!
        #expect(try settings.makeClient { "k" } is AnthropicClient)
        #expect(ModelSettings.keychainAccount(for: "anthropic") == "model.anthropic.apiKey")
    }
}
