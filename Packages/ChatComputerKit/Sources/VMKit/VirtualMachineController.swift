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
    private var holdsBundleLock = false

    /// Snapshots of this machine, oldest first, and the one its current state comes from.
    public private(set) var snapshots: [VMSnapshot] = []
    public private(set) var currentSnapshotID: UUID?
    /// True while a snapshot is being taken or restored; the VM stops and starts again during it.
    public private(set) var isWorkingOnSnapshots = false
    public var snapshotStore: SnapshotStore { SnapshotStore(bundle: bundle) }

    /// Throws `VMError.restoreJournalUnreadable` if an interrupted restore can't be finished; the VM can't
    /// start until someone looks at it, because its files may be half swapped.
    public init(bundle: VMBundle) throws {
        self.bundle = bundle
        // Finish or undo an interrupted restore before reading the spec, which the restore may have replaced.
        try SnapshotStore(bundle: bundle).recoverInterruptedRestore()
        self.spec = try bundle.loadSpec()
        super.init()
        refreshSnapshots()
    }

    /// Starts (or restores) the VM. First boot after install passes provisioning options so the guest
    /// account is created and logged in without anyone clicking through Setup Assistant (macOS 27).
    public func start(provisioning: VZMacGuestProvisioningOptions? = nil) async {
        guard state == .stopped || isError else { return }
        if !holdsBundleLock {
            guard bundle.lock() else {
                state = .error("This virtual Mac is already running in another copy of Chat Computer or in cc-harness.")
                return
            }
            holdsBundleLock = true
        }
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
        do {
            try await machine.pause()
            try await machine.saveMachineStateTo(url: bundle.savedStateURL)
        } catch {
            // Keep the guest running rather than leaving it frozen, and drop a partial state file.
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
            if machine.state == .paused { try? await machine.resume() }
            state = machine.state == .running ? .running : .error(error.localizedDescription)
            throw error
        }
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

    // MARK: Snapshots

    /// Saves the whole machine as a snapshot. A running Mac is suspended, captured with its memory and
    /// resumed (a few seconds, P3: save 3.0 s, restore 2.8 s); a stopped one is captured from disk.
    @discardableResult
    public func takeSnapshot(name: String, thumbnail: Data?) async throws -> VMSnapshot {
        try await withMachineStopped(keepingMemory: true) {
            try snapshotStore.capture(name: name, spec: spec, thumbnail: thumbnail)
        }
    }

    /// Returns the machine to a snapshot. With `savingCurrentAs`, the state being replaced is saved first as a
    /// snapshot of that name, so the restore can be undone. Otherwise a running Mac is simply powered off,
    /// since its state is discarded anyway. Afterwards the Mac resumes from the snapshot's memory or, for a
    /// disk-only snapshot, starts up.
    public func restoreSnapshot(_ id: UUID, savingCurrentAs safetyName: String?, thumbnail: Data?) async throws {
        _ = try snapshotStore.snapshot(id)
        try await withMachineStopped(keepingMemory: safetyName != nil) {
            if let safetyName {
                try snapshotStore.capture(name: safetyName, kind: .safety, spec: spec, thumbnail: thumbnail)
            }
            let restored = try snapshotStore.restore(id, spec: spec)
            spec = restored
        }
    }

    public func renameSnapshot(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try snapshotStore.update(id) { $0.name = name }
        refreshSnapshots()
    }

    public func setSnapshotProtected(_ id: UUID, _ isProtected: Bool) throws {
        try snapshotStore.update(id) { $0.isProtected = isProtected }
        refreshSnapshots()
    }

    public func deleteSnapshot(_ id: UUID) throws {
        guard !isWorkingOnSnapshots else { throw VMError.busy }
        try snapshotStore.delete(id)
        refreshSnapshots()
    }

    /// Records the freshly set up Mac as the protected "Freshly set up" snapshot, if it isn't there yet.
    /// Needs the VM stopped; onboarding calls it right after freezing the golden image, and older machines
    /// get it the first time a snapshot operation stops the VM.
    public func recordInitialSnapshot() throws {
        guard spec.stage == .ready, spec.overlayCount > 0, state == .stopped || isError else { return }
        let disks = DiskStack(bundle: bundle)
        try snapshotStore.captureInitial { url in try disks.createOverlay(at: url, above: 0) }
        refreshSnapshots()
    }

    /// Room a snapshot of the running Mac needs: its memory, plus a reserve so the guest disk can keep growing.
    public var spaceNeededForMemorySnapshot: Int64 { Int64(spec.memoryBytes) + (2 << 30) }

    /// Stops the machine, runs `body`, and brings the machine back to running if it was.
    /// With `keepingMemory`, a running Mac is suspended, so `body` sees its memory in `SavedState.vzvmsave`
    /// and the restart resumes it (unless `body` replaced that file). Otherwise it is powered off.
    private func withMachineStopped<Result>(keepingMemory: Bool, _ body: () throws -> Result) async throws -> Result {
        guard !isWorkingOnSnapshots else { throw VMError.busy }
        guard state == .running || state == .stopped || isError else { throw VMError.busy }
        isWorkingOnSnapshots = true
        defer {
            isWorkingOnSnapshots = false
            refreshSnapshots()
        }
        let wasRunning = state == .running
        if wasRunning, keepingMemory {
            let available = SnapshotStore.availableCapacity(for: bundle.url)
            guard available >= spaceNeededForMemorySnapshot else {
                throw VMError.notEnoughSpace(needed: spaceNeededForMemorySnapshot, available: available)
            }
            try await suspend()
        } else if wasRunning {
            try await forceStop()
        }
        do {
            try recordInitialSnapshot()
            let result = try body()
            if wasRunning { await start() }
            return result
        } catch {
            if wasRunning { await start() }
            throw error
        }
    }

    private func refreshSnapshots() {
        let store = snapshotStore
        snapshots = store.list()
        currentSnapshotID = store.currentID
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
