#if os(macOS)
import Foundation
import Virtualization
import BridgeProtocol

/// Host end of the control channel: listens on the VM's vsock device and speaks BridgeProtocol.
///
/// vsock needs no IP network, ports or passwords, and only this VM can reach the listener.
/// The pairing token additionally proves the agent is the one we installed (proposal §07).
public final class BridgeServer: NSObject, GuestChannel, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    public let vmID: UUID
    private let listener = VZVirtioSocketListener()
    private let session: BridgeSession

    /// `log` receives connection lifecycle events (connect, handshake result, disconnect) for diagnostics.
    public init(vmID: UUID, pairingToken: String, log: (@Sendable (String) -> Void)? = nil) {
        self.vmID = vmID
        self.session = BridgeSession(vmID: vmID, pairingToken: pairingToken, log: log)
        super.init()
        listener.delegate = self
    }

    /// Call on the VM's queue (main) once the VM is created.
    @MainActor
    public func attach(to device: VZVirtioSocketDevice) {
        device.setSocketListener(listener, forPort: Bridge.vsockPort)
    }

    public var isConnected: Bool {
        get async { await session.isPaired }
    }

    public func send(_ envelope: CommandEnvelope) async throws -> CommandResult {
        try await session.send(envelope)
    }

    public func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                         from socketDevice: VZVirtioSocketDevice) -> Bool {
        nonisolated(unsafe) let connection = connection
        Task { await session.adopt(connection) }
        return true
    }
}

/// Owns the current connection, frame decoding and request/response matching.
actor BridgeSession {
    private let vmID: UUID
    private let pairingToken: String

    /// Kept alive on purpose: releasing a `VZVirtioSocketConnection` closes its file descriptor.
    private var connection: VZVirtioSocketConnection?
    private var handle: FileHandle?
    private var decoder = FrameDecoder()
    private var pending: [UUID: CheckedContinuation<CommandResult, Error>] = [:]
    private(set) var isPaired = false
    /// Distinguishes the current connection from a replaced one whose reader is still draining.
    private var generation = 0

    private let log: (@Sendable (String) -> Void)?

    init(vmID: UUID, pairingToken: String, log: (@Sendable (String) -> Void)?) {
        self.vmID = vmID
        self.pairingToken = pairingToken
        self.log = log
    }

    func adopt(_ newConnection: VZVirtioSocketConnection) {
        log?("guest connected\(connection == nil ? "" : " (replacing previous connection)")")
        // A reconnect replaces the old session; anything in flight is now uncertain.
        failAll(BridgeError(.driverFailure, "Guest agent reconnected; earlier commands may or may not have run."))
        closeConnection()
        connection = newConnection
        generation += 1
        let current = generation
        isPaired = false
        decoder = FrameDecoder()

        let handle = FileHandle(fileDescriptor: newConnection.fileDescriptor, closeOnDealloc: false)
        self.handle = handle
        let chunks = AsyncStream<Data> { continuation in
            // POSIX read returns what is available and reports a closed descriptor as -1;
            // `availableData` would raise an Objective-C exception and take the process down,
            // and `read(upToCount:)` blocks until the count is reached.
            handle.readabilityHandler = { handle in
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                guard count > 0 else {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                continuation.yield(Data(buffer[..<count]))
            }
        }
        Task { [weak self] in
            for await chunk in chunks { await self?.receive(chunk, generation: current) }
            await self?.disconnected(generation: current)
        }
    }

    func send(_ envelope: CommandEnvelope) async throws -> CommandResult {
        guard isPaired, let handle else { throw BridgeError(.desktopUnavailable, "Guest agent is not connected.") }
        let frame = try FrameEncoder().encode(HostMessage.command(envelope))
        let id = envelope.commandID
        let timeout = max(envelope.deadline.timeIntervalSinceNow, 1)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try handle.write(contentsOf: frame)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id)
            }
        }
    }

    private func receive(_ chunk: Data, generation: Int) {
        guard generation == self.generation else { return }
        decoder.append(chunk)
        do {
            while let message = try decoder.next(GuestMessage.self) {
                switch message {
                case .hello(let hello):
                    handshake(hello)
                case .response(let response):
                    pending.removeValue(forKey: response.commandID)?.resume(returning: response.result)
                }
            }
        } catch {
            // Malformed or oversized frame: drop the connection rather than guess.
            log?("dropping connection: \(error)")
            closeConnection()
        }
    }

    private func handshake(_ hello: GuestHello) {
        let accepted = hello.protocolVersion == Bridge.protocolVersion
            && hello.vmID == vmID
            && hello.pairingToken == pairingToken
        let welcome = HostWelcome(accepted: accepted, vmID: vmID,
                                  reason: accepted ? nil : "Unknown VM, wrong pairing token, or protocol \(hello.protocolVersion).")
        try? handle?.write(contentsOf: FrameEncoder().encode(HostMessage.welcome(welcome)))
        isPaired = accepted
        log?(accepted ? "handshake accepted (agent \(hello.agentVersion), \(hello.osVersion))"
                      : "handshake rejected: protocol \(hello.protocolVersion), vm \(hello.vmID?.uuidString ?? "nil"), token \(hello.pairingToken == pairingToken ? "ok" : "mismatch")")
        if !accepted { closeConnection() }
    }

    /// Detaches the reader before closing, so it never touches a closed descriptor.
    private func closeConnection() {
        handle?.readabilityHandler = nil
        handle = nil
        connection?.close()
        connection = nil
        isPaired = false
    }

    private func expire(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: BridgeError(.deadlineExceeded, "No answer from the guest before the deadline."))
    }

    private func disconnected(generation: Int) {
        guard generation == self.generation else { return }
        log?("guest disconnected")
        isPaired = false
        failAll(BridgeError(.desktopUnavailable, "Guest agent disconnected."))
    }

    private func failAll(_ error: BridgeError) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
#endif
