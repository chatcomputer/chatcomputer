#if os(macOS)
import Darwin
import Foundation

/// The app's control socket: a Unix domain socket in the user's Application Support folder, 0600 and
/// checked against the peer's user ID, so only this user's processes can drive the virtual Mac.
/// Each connection carries one JSON line each way: a `ControlRequest`, then a `ControlResponse`.
public enum ControlSocket {
    public static var defaultPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatComputer", isDirectory: true)
            .appendingPathComponent("control.sock").path
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func readLine(_ fd: Int32, limit: Int = 64 << 20) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw SocketError("read failed: \(String(cString: strerror(errno)))")
            }
            if count == 0 { return data }
            if let newline = buffer[0..<count].firstIndex(of: 10) {
                data.append(contentsOf: buffer[0..<newline])
                return data
            }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= limit else { throw SocketError("message too large") }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        var bytes = [UInt8](data)
        bytes.append(10)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                throw SocketError("write failed: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }
}

public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Listens on the control socket and hands each request to `handler`.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    public let path: String
    private let handler: Handler
    private var listener: Int32 = -1

    public init(path: String = ControlSocket.defaultPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Never take the socket from a live server (another copy of the app); only clear a stale file.
        if ControlClient.isListening(path) { throw SocketError("another copy of Chat Computer is already listening on \(path)") }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket failed") }
        var address = try ControlSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketError("bind \(path) failed: \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw SocketError("listen failed")
        }
        listener = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "ControlServer"
        thread.start()
    }

    public func stop() {
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // closed by stop()
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            let handler = self.handler
            Thread.detachNewThread {
                guard let line = try? ControlSocket.readLine(client),
                      let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
                    close(client)
                    return
                }
                Task {
                    let response = await handler(request)
                    if let data = try? JSONEncoder().encode(response) { try? ControlSocket.writeAll(client, data) }
                    close(client)
                }
            }
        }
    }
}

/// Sends one request to the app and waits for the answer.
public enum ControlClient {
    public static func send(_ request: ControlRequest, path: String = ControlSocket.defaultPath) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket failed") }
        defer { close(fd) }
        var address = try ControlSocket.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw NotRunning() }
        try ControlSocket.writeAll(fd, try JSONEncoder().encode(request))
        let line = try ControlSocket.readLine(fd)
        guard !line.isEmpty else { throw SocketError("Chat Computer closed the connection without answering") }
        return try JSONDecoder().decode(ControlResponse.self, from: line)
    }

    /// Whether a server accepts connections on `path`.
    public static func isListening(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = try? ControlSocket.address(path) else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    /// Nothing listens on the socket: the app is not running.
    public struct NotRunning: Error {}
}
#endif
