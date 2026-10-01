#if os(macOS)
import Darwin
import Foundation
import BridgeProtocol

/// Guest end of the control channel. Runs inside ChatComputerAgent.app (a LaunchAgent in the
/// auto-logged-in Aqua session), connects to the host over vsock and executes commands with a driver.
public actor AgentService {
    public struct Pairing: Codable, Sendable {
        public var vmID: UUID
        public var pairingToken: String
    }

    public enum Status: Sendable, Equatable {
        case unpaired
        case connecting
        case connected
        case rejected(String)
    }

    private let driver: any DriverAdapter
    private let agentVersion: String
    private let pairingURL: URL
    /// Last lease the host announced; input commands must carry exactly this token.
    private var currentLease: UUID?
    public private(set) var status: Status = .connecting
    private var onStatus: (@Sendable (Status) -> Void)?

    public init(driver: any DriverAdapter, agentVersion: String, pairingURL: URL = AgentService.defaultPairingURL) {
        self.driver = driver
        self.agentVersion = agentVersion
        self.pairingURL = pairingURL
    }

    public static var defaultPairingURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatComputerAgent/pairing.json")
    }

    public func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        onStatus = handler
        handler(status)
    }

    /// Connects and serves forever, reconnecting with backoff (host app restarts, VM restores).
    public func run() async {
        var delay: Duration = .seconds(1)
        while !Task.isCancelled {
            guard let pairing = try? JSONDecoder().decode(Pairing.self, from: Data(contentsOf: pairingURL)) else {
                update(.unpaired)
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            update(.connecting)
            do {
                let handle = try VsockSocket.connectToHost(port: Bridge.vsockPort)
                delay = .seconds(1)
                try await serve(handle: handle, pairing: pairing)
            } catch {
                currentLease = nil
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
    }

    private func serve(handle: FileHandle, pairing: Pairing) async throws {
        defer { try? handle.close() }
        let hello = GuestHello(agentVersion: agentVersion, vmID: pairing.vmID, pairingToken: pairing.pairingToken,
                               osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        try handle.write(contentsOf: FrameEncoder().encode(GuestMessage.hello(hello)))

        var decoder = FrameDecoder()
        for await chunk in Self.chunks(from: handle) {
            decoder.append(chunk)
            while let message = try decoder.next(HostMessage.self) {
                switch message {
                case .welcome(let welcome):
                    guard welcome.accepted else {
                        update(.rejected(welcome.reason ?? "Rejected by host"))
                        return
                    }
                    update(.connected)
                case .command(let envelope):
                    // Sequential on purpose: input actions must never interleave.
                    let result = await execute(envelope, pairing: pairing)
                    let response = ResponseEnvelope(commandID: envelope.commandID, result: result)
                    try handle.write(contentsOf: FrameEncoder().encode(GuestMessage.response(response)))
                }
            }
        }
    }

    private func execute(_ envelope: CommandEnvelope, pairing: Pairing) async -> CommandResult {
        guard envelope.protocolVersion == Bridge.protocolVersion, envelope.vmID == pairing.vmID else {
            return .failure(BridgeError(.protocolMismatch, "Command addressed to another VM or protocol version."))
        }
        guard envelope.deadline > Date() else {
            return .failure(BridgeError(.deadlineExceeded, "Command arrived after its deadline."))
        }
        do {
            switch envelope.command {
            case .health:
                return .health(await driver.health())
            case .capabilities:
                return .capabilities(driver.capabilities)
            case .screenshot(let region):
                return .screenshot(try await driver.screenshot(region: region))
            case .setLease(let token):
                currentLease = token
                return .ok
            case .perform(let action):
                guard let token = envelope.leaseToken, token == currentLease else {
                    return .failure(BridgeError(.leaseRejected, "The agent does not hold input control."))
                }
                return try await driver.perform(action)
            case .cancel:
                // TODO(M2): cancel long-running waits/holds; commands are short and sequential for now.
                return .ok
            }
        } catch let error as BridgeError {
            return .failure(error)
        } catch {
            return .failure(BridgeError(.driverFailure, error.localizedDescription))
        }
    }

    private func update(_ status: Status) {
        self.status = status
        onStatus?(status)
    }

    private static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
    }
}

/// Minimal AF_VSOCK client. `sys/vsock.h` is not exposed through the Darwin module,
/// so the constants and address layout are declared here (xnu bsd/sys/vsock.h).
enum VsockSocket {
    static let addressFamily: Int32 = 40        // AF_VSOCK
    static let hostCID: UInt32 = 2              // VMADDR_CID_HOST

    struct Address {
        var length: UInt8 = UInt8(MemoryLayout<Address>.size)
        var family: UInt8 = UInt8(VsockSocket.addressFamily)
        var reserved: UInt16 = 0
        var port: UInt32
        var cid: UInt32
    }

    static func connectToHost(port: UInt32) throws -> FileHandle {
        let fd = socket(addressFamily, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = Address(port: port, cid: hostCID)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<Address>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .ECONNREFUSED)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
#endif
