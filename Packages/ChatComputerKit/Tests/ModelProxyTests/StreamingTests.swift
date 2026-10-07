import Foundation
import Testing
@testable import ModelProxy

/// Serves canned responses to URLSession: a status and a body, per request in order.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    static func session(_ responses: [(Int, String)]) -> URLSession {
        lock.withLock { self.responses = responses.map { (status: $0.0, body: $0.1) }; requests = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func body(of request: URLRequest) -> JSONValue? {
        let data = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        }
        return data.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let next = Self.lock.withLock { () -> (status: Int, body: String)? in
            Self.requests.append(request)
            return Self.responses.isEmpty ? nil : Self.responses.removeFirst()
        }
        guard let next, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func events(_ lines: String) -> [ServerSentEvents.Event] {
    var parser = ServerSentEvents()
    var result: [ServerSentEvents.Event] = []
    for line in lines.components(separatedBy: "\n") { if let event = parser.feed(line) { result.append(event) } }
    if let event = parser.flush() { result.append(event) }
    return result
}

/// A Messages API stream: thinking with a signature, text, and a tool call whose input arrives in pieces.
private let anthropicStream = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","stop_reason":null,"usage":{"input_tokens":12,"cache_read_input_tokens":900,"cache_creation_input_tokens":0,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The dialog is "}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"open."}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"c2lnbmF0dXJl"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: ping
data: {"type":"ping"}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Clicking Save."}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: content_block_start
data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"left_click","toolset_name":"computer","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"coordinate\\": [64"}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"0, 412]}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":2}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":48}}

event: message_stop
data: {"type":"message_stop"}

"""

/// The same turn as one non-streaming response.
private let anthropicWhole = """
{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","stop_reason":"tool_use","stop_sequence":null,
 "usage":{"input_tokens":12,"cache_read_input_tokens":900,"cache_creation_input_tokens":0,"output_tokens":48},
 "content":[{"type":"thinking","thinking":"The dialog is open.","signature":"c2lnbmF0dXJl"},
            {"type":"text","text":"Clicking Save."},
            {"type":"tool_use","id":"toolu_1","name":"left_click","toolset_name":"computer","input":{"coordinate":[640,412]}}]}
"""

/// A Chat Completions stream as DeepSeek sends it: reasoning, text, a tool call in pieces, usage last.
private let chatStream = """
data: {"id":"c1","model":"deepseek-flash","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"Need to save."},"finish_reason":null}]}

data: {"id":"c1","model":"deepseek-flash","choices":[{"index":0,"delta":{"content":"Saving the "},"finish_reason":null}]}

data: {"id":"c1","model":"deepseek-flash","choices":[{"index":0,"delta":{"content":"file."},"finish_reason":null}]}

data: {"id":"c1","model":"deepseek-flash","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_9","type":"function","function":{"name":"save_file","arguments":"{\\"name\\":"}}]},"finish_reason":null}]}

data: {"id":"c1","model":"deepseek-flash","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"note.txt\\"}"}}]},"finish_reason":null}]}

data: {"id":"c1","model":"deepseek-flash","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

data: {"id":"c1","model":"deepseek-flash","choices":[],"usage":{"prompt_tokens":5000,"completion_tokens":40,"prompt_cache_hit_tokens":4096}}

data: [DONE]

"""

private let chatWhole = """
{"id":"c1","model":"deepseek-flash","usage":{"prompt_tokens":5000,"completion_tokens":40,"prompt_cache_hit_tokens":4096},
 "choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":"Saving the file.","reasoning_content":"Need to save.",
   "tool_calls":[{"id":"call_9","type":"function","function":{"name":"save_file","arguments":"{\\"name\\":\\"note.txt\\"}"}}]}}]}
"""

// Serialized: the stub serves one shared queue of responses.
@Suite(.serialized) struct StreamingTests {
    @Test func serverSentEventsSplitOnBlankLines() {
        let parsed = events("event: a\ndata: 1\ndata: 2\n\n: keep-alive\ndata: x\n")
        #expect(parsed == [.init(name: "a", data: "1\n2"), .init(name: nil, data: "x")])
    }

    @Test func anthropicStreamRebuildsTheSameTurn() throws {
        var assembler = AnthropicStreamAssembler()
        var seen: [String] = []
        for event in events(anthropicStream) where try assembler.apply(event) { seen.append(assembler.currentText) }
        let streamed = try AnthropicClient.parse(status: 200, retryAfter: nil, body: try StableJSON.encoder.encode(assembler.body()))
        let whole = try AnthropicClient.parse(status: 200, retryAfter: nil, body: Data(anthropicWhole.utf8))
        // Byte for byte the same history: the thinking signature and the tool input included.
        #expect(streamed == whole)
        #expect(seen.contains("The dialog is open."))
        #expect(seen.last == "Clicking Save.")
    }

    @Test func chatCompletionsStreamRebuildsTheSameTurn() throws {
        var assembler = ChatCompletionsStreamAssembler()
        var seen: [String] = []
        for event in events(chatStream) where assembler.apply(event) { seen.append(assembler.currentText) }
        #expect(assembler.done)
        let streamed = try OpenAICompatibleClient.parse(status: 200, retryAfter: nil, body: try StableJSON.encoder.encode(assembler.body()))
        let whole = try OpenAICompatibleClient.parse(status: 200, retryAfter: nil, body: Data(chatWhole.utf8))
        #expect(streamed == whole)
        #expect(streamed.cachedInputTokens == 4096)
        // Reasoning shows until the reply's own text starts.
        #expect(seen.first == "Need to save.")
        #expect(seen.last == "Saving the file.")
    }

    @Test func clientStreamsAndAsksForUsage() async throws {
        let session = StubProtocol.session([(200, chatStream)])
        let client = OpenAICompatibleClient(configuration: .init(model: "deepseek-flash", baseURL: URL(string: "https://example.invalid/v1")!),
                                            session: session, apiKey: { "key" })
        let texts = TextLog()
        let response = try await client.respond(system: "s", tools: [], messages: [["role": "user", "content": "hi"]],
                                                onText: { texts.add($0) })
        #expect(response.blocks.contains(.text("Saving the file.")))
        let sent = StubProtocol.lock.withLock { StubProtocol.requests.first }.flatMap(StubProtocol.body)
        #expect(sent?["stream"] == true)
        #expect(sent?["stream_options"]?["include_usage"] == true)
        #expect(!texts.all.isEmpty)
    }

    @Test func aStreamThatEndsEarlyIsResent() async throws {
        let cut = chatStream.components(separatedBy: "\n").prefix(4).joined(separator: "\n") + "\n\n"
        let session = StubProtocol.session([(200, cut)])
        let client = OpenAICompatibleClient(configuration: .init(model: "m", baseURL: URL(string: "https://example.invalid/v1")!),
                                            session: session, apiKey: { "key" })
        await #expect(throws: ModelError.network("The response stream ended early.")) {
            try await client.respond(system: "s", tools: [], messages: [], onText: { _ in })
        }
        // Network errors are transient: the runner sends the request again.
        #expect(ModelError.network("x").isTransient)
    }

    @Test func anEndpointThatRefusesStreamingGetsAPlainRequest() async throws {
        let whole = "{\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\"Hello.\"}}]}"
        let session = StubProtocol.session([(400, "{\"error\":{\"message\":\"stream_options is not supported\"}}"), (200, whole)])
        let client = OpenAICompatibleClient(configuration: .init(model: "m", baseURL: URL(string: "https://example.invalid/v1")!),
                                            session: session, apiKey: { "key" })
        let response = try await client.respond(system: "s", tools: [], messages: [], onText: { _ in })
        #expect(response.blocks == [.text("Hello.")])
        let bodies = StubProtocol.lock.withLock { StubProtocol.requests }.compactMap(StubProtocol.body)
        #expect(bodies.count == 2)
        #expect(bodies.last?["stream"] == nil)
    }

    @Test func anOverloadInTheMiddleOfAStreamIsRetryable() throws {
        var assembler = AnthropicStreamAssembler()
        for event in events("event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n") {
            _ = try assembler.apply(event)
        }
        let error = try #require(assembler.error)
        #expect(ModelError.fromStreamError(error) == .overloaded)
    }
}

final class TextLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ text: String) { lock.withLock { values.append(text) } }
    var all: [String] { lock.withLock { values } }
}
