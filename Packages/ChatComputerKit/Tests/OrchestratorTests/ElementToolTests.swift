import Foundation
import Testing
import BridgeProtocol
import ChatCore
import ModelProxy
@testable import Orchestrator

/// A guest whose agent reads its accessibility tree: a dialog with a Save button and two Cancel buttons.
actor ElementGuest: GuestChannel {
    nonisolated let vmID = UUID()
    let supportsTree: Bool
    private(set) var clicks: [ScreenPoint] = []
    private(set) var queries: [String?] = []

    init(supportsTree: Bool = true) { self.supportsTree = supportsTree }

    static let elements = [
        UIElement(id: 1, role: "button", name: "Save", value: nil, enabled: true, frame: ScreenRect(x0: 600, y0: 400, x1: 680, y1: 424)),
        UIElement(id: 2, role: "button", name: "Cancel", value: nil, enabled: true, frame: ScreenRect(x0: 500, y0: 400, x1: 580, y1: 424)),
        UIElement(id: 3, role: "menuitem", name: "Cancel", value: nil, enabled: true, frame: ScreenRect(x0: 10, y0: 30, x1: 90, y1: 50)),
        UIElement(id: 4, role: "textfield", name: "Save As", value: "Untitled", enabled: true, frame: ScreenRect(x0: 400, y0: 300, x1: 700, y1: 322)),
    ]

    func send(_ envelope: CommandEnvelope) async throws -> CommandResult {
        switch envelope.command {
        case .capabilities:
            return .capabilities(DriverCapabilities(driver: "fake", driverVersion: "1", supportsAccessibilityTree: supportsTree,
                                                    supportsBrowserSnapshot: false, supportsBackgroundInput: false))
        case .uiElements(let query):
            queries.append(query)
            let matching = Self.elements.filter { query == nil || $0.name.localizedCaseInsensitiveContains(query!) }
            return .elements(UIElementList(app: "TextEdit", elements: matching, truncated: false))
        case .perform(.click(_, _, let at?, _)):
            clicks.append(at)
            return .ok
        case .screenshot:
            return .screenshot(Screenshot(imageData: Data([0x89]), mediaType: "image/png", width: 1280, height: 800, capturedAt: Date(), observationVersion: 1))
        default:
            return .ok
        }
    }
}

/// Records the tools offered with each request.
actor ToolRecordingModel: ModelClient {
    nonisolated let modelID = "recording"
    private var turns: [[JSONValue]]
    private(set) var tools: [[String]] = []
    private(set) var systems: [String] = []
    private(set) var requests: [[JSONValue]] = []

    init(turns: [[JSONValue]]) { self.turns = turns }

    func respond(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ModelResponse {
        self.tools.append(tools.compactMap { $0["name"]?.stringValue })
        systems.append(system)
        requests.append(messages)
        guard !turns.isEmpty else { throw ModelError.malformedResponse }
        return ModelResponse(content: turns.removeFirst(), stopReason: "tool_use", inputTokens: 100, outputTokens: 10, servedModel: modelID)
    }
}

private func runner(_ model: ToolRecordingModel, _ guest: ElementGuest) -> AgentRunner {
    let folders = SharedFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)"))
    return AgentRunner(goal: "Save the document", dependencies: .init(
        model: model, guest: guest, store: InMemoryTaskStore(), lease: ControlLease(), folders: folders))
}

private func lastToolResult(_ model: ToolRecordingModel, request: Int) async -> JSONValue? {
    await model.requests[request].last?["content"]?.arrayValue?.first { $0["type"] == "tool_result" }
}

private func text(of result: JSONValue?) -> String {
    if let text = result?["content"]?.stringValue { return text }
    return result?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined() ?? ""
}

@Suite struct ElementToolTests {
    @Test func offeredOnlyWhenTheAgentReadsTheTree() async throws {
        let done: [JSONValue] = [.object(["type": "text", "text": "Done."])]
        let withTree = ToolRecordingModel(turns: [done])
        try await runner(withTree, ElementGuest()).start()
        #expect(await withTree.tools.first?.contains("click_element") == true)
        #expect(await withTree.systems.first?.contains("click_element") == true)

        let without = ToolRecordingModel(turns: [done])
        try await runner(without, ElementGuest(supportsTree: false)).start()
        #expect(await without.tools.first?.contains("click_element") == false)
        #expect(await without.systems.first?.contains("click_element") == false)
    }

    @Test func clickByNameClicksTheCentreAndShowsTheScreen() async throws {
        let model = ToolRecordingModel(turns: [
            [toolUse("t1", "click_element", ["name": "save", "role": "button"], computer: false)],
            [.object(["type": "text", "text": "Saved."])],
        ])
        let guest = ElementGuest()
        try await runner(model, guest).start()

        #expect(await guest.clicks == [ScreenPoint(x: 640, y: 412)])
        let result = await lastToolResult(model, request: 1)
        #expect(result?["is_error"] != true)
        #expect(text(of: result).contains("Clicked button \"Save\""))
        // The click changed the screen, so a fresh screenshot follows.
        #expect(await model.requests[1].last?["content"]?.arrayValue?.last?["type"] == "image")
    }

    @Test func anAmbiguousNameListsTheCandidatesInsteadOfClicking() async throws {
        let model = ToolRecordingModel(turns: [
            [toolUse("t1", "click_element", ["name": "Cancel"], computer: false)],
            [toolUse("t2", "click_element", ["id": 2], computer: false)],
            [.object(["type": "text", "text": "Cancelled."])],
        ])
        let guest = ElementGuest()
        try await runner(model, guest).start()

        let first = await lastToolResult(model, request: 1)
        #expect(first?["is_error"] == true)
        #expect(text(of: first).contains("[2] button \"Cancel\""))
        #expect(text(of: first).contains("[3] menuitem \"Cancel\""))
        // Then by id, from the candidates it was shown.
        #expect(await guest.clicks == [ScreenPoint(x: 540, y: 412)])
    }

    @Test func findElementsListsControlsWithTheirPositions() async throws {
        let model = ToolRecordingModel(turns: [
            [toolUse("t1", "find_elements", [:], computer: false)],
            [.object(["type": "text", "text": "Listed."])],
        ])
        let guest = ElementGuest()
        try await runner(model, guest).start()

        let listing = text(of: await lastToolResult(model, request: 1))
        #expect(listing.contains("[1] button \"Save\" at (640, 412)"))
        #expect(listing.contains("[4] textfield \"Save As\" value \"Untitled\""))
        #expect(await guest.clicks.isEmpty)
    }
}
