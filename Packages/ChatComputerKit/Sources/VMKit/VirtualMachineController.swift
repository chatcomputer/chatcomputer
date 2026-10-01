#if os(macOS)
import Foundation
import Observation
import Virtualization

/// Owns the one `VZVirtualMachine` in this process. Because the VM lives here (not in a helper
/// process), `VZVirtualMachineView` can display it directly — the reason we don't use Lume.
@MainActor
@Observable
public final class VirtualMachineController: NSObject {
    public enum State: Equatable {
        case stopped
        case starting
        case running
        case paused
        case saving
        case error(String)
    }

    public let bundle: VMBundle
    public private(set) var spec: VMSpec
    public private(set) var state: State = .stopped
    public private(set) var virtualMachine: VZVirtualMachine?

    /// Called with the vsock device once the VM starts, so the bridge can listen on it.
    public var onSocketDeviceReady: ((VZVirtioSocketDevice) -> Void)?

    public let network = NetworkProvider()

    public init(bundle: VMBundle) throws {
        self.bundle = bundle
        self.spec = try bundle.loadSpec()
    }

    /// Starts (or restores) the VM. First boot after install passes provisioning options so the guest
    /// account is created and logged in without anyone clicking through Setup Assistant (macOS 27).
    public func start(provisioning: VZMacGuestProvisioningOptions? = nil) async {
        guard state == .stopped || isError else { return }
        state = .starting
        do {
            let configuration = try VMConfigurationFactory(bundle: bundle, network: network).make(spec: spec)
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = self
            virtualMachine = machine
            if let socket = machine.socketDevices.first as? VZVirtioSocketDevice {
                onSocketDeviceReady?(socket)
            }

            if provisioning == nil, FileManager.default.fileExists(atPath: bundle.savedStateURL.path) {
                do {
                    try await machine.restoreMachineStateFrom(url: bundle.savedStateURL)
                    try await machine.resume()
                    try? FileManager.default.removeItem(at: bundle.savedStateURL)
                    state = .running
                    return
                } catch {
                    // Saved state is tied to this Mac, account and OS build; fall back to a cold boot.
                    try? FileManager.default.removeItem(at: bundle.savedStateURL)
                }
            }

            let options = VZMacOSVirtualMachineStartOptions()
            if let provisioning {
                try options.setGuestProvisioning(provisioning)
            }
            try await machine.start(options: options)
            state = .running
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Suspends to disk so the next launch resumes where the user left off.
    public func suspend() async throws {
        guard let machine = virtualMachine, state == .running else { throw VMError.notRunning }
        state = .saving
        try await machine.pause()
        try await machine.saveMachineStateTo(url: bundle.savedStateURL)
        try await machine.stop()
        virtualMachine = nil
        state = .stopped
    }

    /// Asks the guest to shut down cleanly.
    ///
    /// Note: in a macOS guest this only opens the "Shut down now?" dialog, which never
    /// completes by itself. Prefer `shutDown(viaGuest:timeout:)`.
    public func requestShutdown() throws {
        guard let machine = virtualMachine else { throw VMError.notRunning }
        try machine.requestStop()
    }

    /// Shuts the guest down cleanly and waits for it to stop.
    ///
    /// `viaGuest` asks the guest agent to shut down from inside (see `GuestCommand.shutdown`);
    /// without an agent, the VM stop request is used and someone must confirm the guest's dialog.
    /// Throws if the guest is still running after `timeout`; it is never forced off here,
    /// because callers such as freezing the golden image need a clean disk.
    public func shutDown(viaGuest: (() async throws -> Void)?, timeout: Duration = .seconds(150)) async throws {
        guard virtualMachine != nil, state == .running else { return }
        if let viaGuest {
            do { try await viaGuest() } catch { try requestShutdown() }
        } else {
            try requestShutdown()
        }
        let deadline = ContinuousClock.now + timeout
        while state != .stopped {
            guard ContinuousClock.now < deadline else { throw VMError.shutdownTimedOut }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    public func forceStop() async throws {
        guard let machine = virtualMachine else { return }
        try await machine.stop()
        virtualMachine = nil
        state = .stopped
    }

    public func updateSpec(_ change: (inout VMSpec) throws -> Void) throws {
        var copy = spec
        try change(&copy)
        try bundle.save(copy)
        spec = copy
    }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }
}

extension VirtualMachineController: VZVirtualMachineDelegate {
    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            self.virtualMachine = nil
            self.state = .stopped
        }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.virtualMachine = nil
            self.state = .error(message)
        }
    }
}
#endif
