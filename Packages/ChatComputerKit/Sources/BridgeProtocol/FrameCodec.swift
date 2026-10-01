import Foundation

/// Length-prefixed JSON frames: 4-byte big-endian payload length, then UTF-8 JSON.
public struct FrameEncoder: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try Self.jsonEncoder.encode(value)
        guard payload.count <= Bridge.maxFrameBytes else {
            throw FrameError.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// Incremental decoder: feed it bytes as they arrive from the socket, collect complete frames.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the next complete frame, or `nil` if more bytes are needed.
    public mutating func next<T: Decodable>(_ type: T.Type) throws -> T? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= Bridge.maxFrameBytes else {
            throw FrameError.frameTooLarge(length)
        }
        guard buffer.count >= 4 + length else { return nil }
        let start = buffer.startIndex
        let payload = buffer.subdata(in: (start + 4)..<(start + 4 + length))
        buffer.removeSubrange(start..<(start + 4 + length))
        return try Self.jsonDecoder.decode(T.self, from: payload)
    }

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum FrameError: Error, Equatable {
    case frameTooLarge(Int)
}
