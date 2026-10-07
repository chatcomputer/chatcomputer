import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Server-sent events, as both the Anthropic Messages API and OpenAI-compatible endpoints stream them.
/// Fed one line at a time; yields an event when a blank line ends it.
struct ServerSentEvents {
    struct Event: Equatable {
        var name: String?
        var data: String
    }

    private var name: String?
    private var data: [String] = []

    mutating func feed(_ line: String) -> Event? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }   // comment or keep-alive
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    /// The event still open when the stream ends without a final blank line.
    mutating func flush() -> Event? {
        defer { name = nil; data = [] }
        guard !data.isEmpty else { return nil }
        return Event(name: name, data: data.joined(separator: "\n"))
    }
}

/// What a streaming turn shows while it arrives: the text of the block being written.
public typealias PartialTextHandler = @Sendable (String) -> Void

/// Rebuilds a Messages API response from its stream, block by block, into the same JSON a non-streaming request
/// returns, so it goes through the same parsing and into the history unchanged: text, thinking with its
/// signature, tool calls with their input, and any other block as the server started it.
struct AnthropicStreamAssembler {
    private var message: [String: JSONValue] = [:]
    private var blocks: [Int: [String: JSONValue]] = [:]
    private var partialJSON: [Int: String] = [:]
    private(set) var error: JSONValue?
    /// The block being written, for the live view.
    private(set) var currentText = ""

    /// Applies one event; returns true when the visible text changed.
    mutating func apply(_ event: ServerSentEvents.Event) throws -> Bool {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8)) else { return false }
        switch json["type"]?.stringValue ?? event.name {
        case "message_start":
            if case .object(let start)? = json["message"] { message = start }
        case "content_block_start":
            guard let index = json["index"]?.intValue, case .object(let block)? = json["content_block"] else { return false }
            blocks[index] = block
            if let text = block["text"]?.stringValue ?? block["thinking"]?.stringValue {
                currentText = text
                return true
            }
        case "content_block_delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"], var block = blocks[index] else { return false }
            var visible = false
            switch delta["type"]?.stringValue {
            case "text_delta":
                block["text"] = .string((block["text"]?.stringValue ?? "") + (delta["text"]?.stringValue ?? ""))
                currentText = block["text"]?.stringValue ?? ""
                visible = true
            case "thinking_delta":
                block["thinking"] = .string((block["thinking"]?.stringValue ?? "") + (delta["thinking"]?.stringValue ?? ""))
                currentText = block["thinking"]?.stringValue ?? ""
                visible = true
            case "signature_delta":
                block["signature"] = .string((block["signature"]?.stringValue ?? "") + (delta["signature"]?.stringValue ?? ""))
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
            case "citations_delta":
                if let citation = delta["citation"] {
                    block["citations"] = .array((block["citations"]?.arrayValue ?? []) + [citation])
                }
            default:
                break
            }
            blocks[index] = block
            return visible
        case "content_block_stop":
            guard let index = json["index"]?.intValue, let raw = partialJSON.removeValue(forKey: index), !raw.isEmpty else { return false }
            guard let input = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else { throw ModelError.malformedResponse }
            blocks[index]?["input"] = input
        case "message_delta":
            if case .object(let delta)? = json["delta"] {
                for (key, value) in delta { message[key] = value }
            }
            if case .object(let usage)? = json["usage"] {
                var merged = message["usage"]?.objectValue ?? [:]
                for (key, value) in usage { merged[key] = value }
                message["usage"] = .object(merged)
            }
        case "error":
            error = json
        default:
            break   // ping, message_stop
        }
        return false
    }

    /// The response as one JSON body, for `AnthropicClient.parse`.
    func body() -> JSONValue {
        var result = message
        result["content"] = .array(blocks.keys.sorted().compactMap { blocks[$0].map(JSONValue.object) })
        return .object(result)
    }
}

/// Rebuilds a Chat Completions response from its chunks into the non-streaming shape (`choices[0].message`),
/// so `OpenAICompatibleClient.parse` treats it exactly as before: content, `reasoning_content`, tool calls with
/// their arguments and any vendor `extra_content`, the finish reason and usage.
struct ChatCompletionsStreamAssembler {
    private var content = ""
    private var reasoning = ""
    private var calls: [Int: [String: JSONValue]] = [:]
    private var arguments: [Int: String] = [:]
    private var names: [Int: String] = [:]
    private var finishReason: JSONValue = .null
    private var usage: JSONValue?
    private var model: JSONValue?
    private(set) var error: JSONValue?
    private(set) var done = false

    var currentText: String { content.isEmpty ? reasoning : content }

    mutating func apply(_ event: ServerSentEvents.Event) -> Bool {
        if event.data == "[DONE]" { done = true; return false }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8)) else { return false }
        if let error = json["error"] { self.error = ["error": error]; return false }
        if model == nil, let name = json["model"] { model = name }
        if let usage = json["usage"], usage != .null { self.usage = usage }
        guard let choice = json["choices"]?.arrayValue?.first else { return false }
        if let reason = choice["finish_reason"], reason != .null { finishReason = reason }
        guard let delta = choice["delta"] else { return false }
        var visible = false
        if let text = delta["content"]?.stringValue, !text.isEmpty { content += text; visible = true }
        if let text = delta["reasoning_content"]?.stringValue, !text.isEmpty { reasoning += text; visible = content.isEmpty }
        for call in delta["tool_calls"]?.arrayValue ?? [] {
            let index = call["index"]?.intValue ?? 0
            var entry = calls[index] ?? ["type": "function"]
            if let id = call["id"]?.stringValue, !id.isEmpty { entry["id"] = .string(id) }
            if let extra = call["extra_content"], extra != .null { entry["extra_content"] = extra }
            if let name = call["function"]?["name"]?.stringValue { names[index, default: ""] += name }
            if let piece = call["function"]?["arguments"]?.stringValue { arguments[index, default: ""] += piece }
            calls[index] = entry
        }
        return visible
    }

    /// The response as one JSON body, for `OpenAICompatibleClient.parse`.
    func body() -> JSONValue {
        var message: [String: JSONValue] = ["role": "assistant", "content": content.isEmpty ? .null : .string(content)]
        if !reasoning.isEmpty { message["reasoning_content"] = .string(reasoning) }
        if !calls.isEmpty {
            message["tool_calls"] = .array(calls.keys.sorted().map { index in
                var call = calls[index] ?? [:]
                call["function"] = ["name": .string(names[index] ?? ""), "arguments": .string(arguments[index] ?? "")]
                return .object(call)
            })
        }
        var result: [String: JSONValue] = ["choices": [["index": 0, "message": .object(message), "finish_reason": finishReason]]]
        if let usage { result["usage"] = usage }
        if let model { result["model"] = model }
        return .object(result)
    }
}

/// Reads a streamed response line by line. A non-200 status keeps its body for the usual error parsing.
enum StreamTransport {
    struct Opened {
        var status: Int
        var retryAfter: String?
        var lines: AsyncThrowingStream<String, Error>
    }

    static func open(_ request: URLRequest, session: URLSession) async throws -> Opened {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ModelError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ModelError.malformedResponse }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    // `lines` drops empty lines, which end SSE events, so split on newlines by hand.
                    var buffer = Data()
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            var line = String(decoding: buffer, as: UTF8.self)
                            if line.hasSuffix("\r") { line.removeLast() }
                            continuation.yield(line)
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ModelError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return Opened(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "retry-after"), lines: lines)
    }

    /// The whole body of a failed request, for the status-specific error.
    static func collect(_ lines: AsyncThrowingStream<String, Error>) async -> Data {
        var text: [String] = []
        do { for try await line in lines { text.append(line) } } catch {}
        return Data(text.joined(separator: "\n").utf8)
    }
}

/// Live text is shown at most this often, so a fast stream doesn't re-lay out the chat on every token.
struct PartialThrottle {
    var interval: TimeInterval = 0.1
    private var last = Date.distantPast

    mutating func due(now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

/// Whether an endpoint has refused streaming; then the client stops asking for it.
final class StreamingSupport: @unchecked Sendable {
    private let lock = NSLock()
    private var refused = false

    var enabled: Bool { lock.withLock { !refused } }
    func refuse() { lock.withLock { refused = true } }

    /// A 400 that names streaming (`stream`, `stream_options`): the endpoint doesn't stream.
    static func isRefusal(_ error: Error) -> Bool {
        guard case ModelError.badRequest(let message) = error else { return false }
        return message.lowercased().contains("stream")
    }
}

extension ModelError {
    /// An `error` event sent in the middle of a stream (Anthropic: overloaded, rate limit, api error).
    static func fromStreamError(_ json: JSONValue) -> ModelError {
        let message = json["error"]?["message"]?.stringValue ?? "The stream reported an error."
        switch json["error"]?["type"]?.stringValue {
        case "overloaded_error": return .overloaded
        case "rate_limit_error": return .rateLimited(retryAfter: nil)
        case "authentication_error", "permission_error": return .authentication(message)
        case "invalid_request_error": return .badRequest(message)
        default: return .server(status: 500, message: message)
        }
    }
}
