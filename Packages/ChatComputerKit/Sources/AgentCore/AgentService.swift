#if os(macOS)
import AppKit
import ApplicationServices
import BridgeProtocol
import Carbon.HIToolbox
import Darwin
import Foundation
import ScreenCaptureKit

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
            // A rejection will not fix itself by retrying quickly (wrong token or VM); wait longer.
            if case .rejected = status { delay = .seconds(30) }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
    }

    private func serve(handle: FileHandle, pairing: Pairing) async throws {
        defer {
            handle.readabilityHandler = nil
            try? handle.close()
        }
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
            case .shutdown:
                try await GuestShutdown.begin()
                return .ok
            case .preparePermission(let kind):
                await PermissionSetup.prepare(kind)
                return .ok
            case .restartAgent:
                // Exit after the reply has gone out; launchd restarts the agent (KeepAlive).
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(300))
                    exit(0)
                }
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
    }
}

/// Shuts the guest down via loginwindow's "really shut down" Apple event (`aevtrsdn`).
/// Verified on macOS 27.0.1: no Automation consent is needed, and the confirmation it shows
/// shuts down by itself after 60 seconds. With Accessibility granted, Return confirms it at once.
enum GuestShutdown {
    static func begin() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"loginwindow\" to \u{00AB}event aevtrsdn\u{00BB}"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError(.driverFailure, "loginwindow refused the shutdown request (osascript exit \(process.terminationStatus)).")
        }
        guard AXIsProcessTrusted() else { return }
        try await Task.sleep(for: .seconds(2))
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: down)?.post(tap: .cghidEventTap)
        }
    }
}

/// Puts the agent into the privacy list and opens the matching pane, so whoever grants the
/// permission (the user, or the host via `HostControl`) only has to flip one switch.
enum PermissionSetup {
    @MainActor
    static func prepare(_ kind: PermissionKind) {
        // Only called while the permission is missing. An entry left by a build with a different
        // signature looks granted in the list but does not apply to this binary; clear it so the
        // prompt below registers this one (observed on macOS 27 after replacing an ad hoc build).
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", kind.tccService, Bundle.main.bundleIdentifier ?? "app.chatcomputer.agent"]
        try? reset.run()
        reset.waitUntilExit()
        // A request right after the reset can be dropped (observed for screen recording on macOS 27).
        Thread.sleep(forTimeInterval: 0.5)

        let pane: String
        switch kind {
        case .accessibility:
            // The prompt is what adds the app to the list; its own button opens the pane too.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            pane = "Privacy_Accessibility"
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            // Trying to list shareable content also registers the app in the Screen Recording list.
            Task { _ = try? await SCShareableContent.current }
            pane = "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
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
