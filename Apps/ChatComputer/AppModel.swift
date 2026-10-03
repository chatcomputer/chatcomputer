import AppKit
import BridgeProtocol
import ChatCore
import HostControl
import GuestBridge
import ModelProxy
import Observation
import Orchestrator
import VMKit
import Virtualization

struct ChatItem: Identifiable, Equatable {
    enum Role { case user, agent, action, system }
    let id = UUID()
    let role: Role
    let text: String
    var files: [URL] = []
}

/// App-wide state: the one VM, its bridge, and the current task.
@MainActor
@Observable
final class AppModel {
    let bundle = VMBundle(url: VMBundle.defaultLocation)
    /// Secrets in files: the VM's in its bundle, API keys in Application Support (see `HostSecretStore`).
    let secrets = HostSecretStore(
        machineFile: VMBundle(url: VMBundle.defaultLocation).secretStore().url,
        credentialsFile: VMBundle.defaultLocation.deletingLastPathComponent().appendingPathComponent("credentials.json"),
        legacy: KeychainStore())
    let lease = ControlLease()
    let store = InMemoryTaskStore()   // TODO(M2): SQLite-backed store

    private(set) var vm: VirtualMachineController?
    /// The on-screen VM view; host-level control (`HostDisplay`) reads and drives the guest through it.
    weak var guestView: VZVirtualMachineView?
    private(set) var bridge: BridgeServer?
    private(set) var runner: AgentRunner?

    var transcript: [ChatItem] = []
    private(set) var phase: TaskPhase = .ready
    private(set) var tokens: (input: Int, output: Int) = (0, 0)
    var errorMessage: String?

    var onboarding = OnboardingState()

    /// A snapshot being taken or restored, shown over the guest screen (see Snapshots.swift).
    var snapshotActivity: SnapshotActivity?
    var showingSnapshots = false
    var showingSharedFolders = false
    /// Files to attach to the next task; copied into its inbox when it starts.
    var pendingAttachments: [URL] = []

    /// A coding agent outside the app (via `chatcomputer` or MCP) that holds the input lease now.
    var externalHolder: String?
    /// A coding agent the user took control from; it waits until the user hands control back.
    var externalBlockedBy: String?
    private(set) var external: ExternalControl?

    /// The right panel shows only a narrow rail of controls, e.g. while a coding agent drives the virtual Mac.
    private(set) var isPanelCollapsed = UserDefaults.standard.bool(forKey: "panelCollapsed")
    /// Chat messages seen before the panel was collapsed, for the rail's unread badge.
    private(set) var seenMessageCount = 0

    /// Which provider, protocol, endpoint and model tasks use. Saved in user defaults.
    private(set) var modelSettings: ModelSettings = {
        guard let data = UserDefaults.standard.data(forKey: "modelSettings"),
              let saved = try? JSONDecoder().decode(ModelSettings.self, from: data) else { return .default }
        return saved
    }()

    func saveModelSettings(_ settings: ModelSettings) {
        modelSettings = settings
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "modelSettings") }
    }

    /// Client for the given settings, with the key read from the secret store at request time.
    func makeModelClient(for settings: ModelSettings) throws -> any ModelClient {
        let secrets = self.secrets
        let account = settings.secretAccount
        let width = (vm?.spec.displayWidth ?? 2560) / 2
        let height = (vm?.spec.displayHeight ?? 1600) / 2
        return try settings.makeClient(displayWidth: width, displayHeight: height) { try secrets.read(account) }
    }
    var autoOnboardingStarted = false
    private var devTaskStarted = false

    /// Whether onboarding has finished. Decided once at launch and set by the last onboarding step,
    /// never re-read from disk while the app runs (the VM's stage turns `.ready` one step earlier,
    /// before the model is connected).
    private(set) var isReady = false

    /// The guest display's shape; the left pane always shows it at this ratio.
    var guestAspectRatio: CGFloat {
        guard let spec = vm?.spec, spec.displayHeight > 0 else { return WorkspaceMetrics.guestAspect }
        return CGFloat(spec.displayWidth) / CGFloat(spec.displayHeight)
    }
    var agentHoldsInput: Bool { phase == .running || externalHolder != nil }

    /// The built-in agent has a task that isn't finished.
    var isRunningTask: Bool { runner != nil && !(phase.isTerminal || phase == .ready) }

    /// Chat messages (not steps) that arrived while the panel was collapsed.
    var unreadMessageCount: Int { isPanelCollapsed ? max(0, messageCount - seenMessageCount) : 0 }
    private var messageCount: Int { transcript.count { $0.role != .action } }

    /// Collapses the panel to the rail, or expands it. The window changes width so the guest screen keeps its size.
    func setPanelCollapsed(_ collapsed: Bool) {
        guard collapsed != isPanelCollapsed else { return }
        let delta = WorkspaceMetrics.panelWidth - WorkspaceMetrics.railWidth
        var frame = guestView?.window?.frame
        if var target = frame {
            target.size.width += collapsed ? -delta : delta
            if !collapsed, let screen = guestView?.window?.screen?.visibleFrame {
                target.size.width = min(target.width, screen.width)
                if target.maxX > screen.maxX { target.origin.x = max(screen.minX, screen.maxX - target.width) }
            }
            frame = target
        }
        isPanelCollapsed = collapsed
        seenMessageCount = messageCount
        UserDefaults.standard.set(collapsed, forKey: "panelCollapsed")
        if let frame { guestView?.window?.setFrame(frame, display: true, animate: true) }
    }

    init() {
        isReady = (try? bundle.loadSpec().stage) == .ready
        if bundle.exists { loadVM() }
        applyDevelopmentModel()
        let external = ExternalControl(model: self)
        external.start()
        self.external = external
    }

    // MARK: Development switches (environment variables, never set in normal use)

    /// CC_DEV_MODEL="provider:protocol:model" (e.g. "deepseek:openAI:deepseek-chat") with CC_DEV_API_KEY
    /// configures the model as if entered in the form; the app stores the key like one typed in the form.
    private func applyDevelopmentModel() {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["CC_DEV_MODEL"] else { return }
        let parts = value.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let provider = ModelCatalog.provider(parts[0]), let kind = ModelProtocol(rawValue: parts[1]) else {
            errorMessage = "CC_DEV_MODEL must look like provider:protocol:model, for example deepseek:openAI:deepseek-chat."
            return
        }
        var settings = ModelSettings.preset(provider)
        settings.protocolKind = kind
        settings.baseURL = provider.endpoints[kind] ?? settings.baseURL
        settings.model = parts[2]
        if let key = environment["CC_DEV_API_KEY"], !key.isEmpty {
            do { try secrets.write(key, for: settings.secretAccount) } catch { errorMessage = "Could not store the API key: \(error)" }
        }
        saveModelSettings(settings)
        if (try? bundle.loadSpec().stage) == .ready { isReady = true }
    }

    /// CC_DEV_LOG=/path appends every runner update to that file, for unattended runs.
    private func devLog(_ update: RunnerUpdate) {
        guard let path = ProcessInfo.processInfo.environment["CC_DEV_LOG"], !path.isEmpty else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(update)\n"
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// CC_DEV_TASK="…" submits that message once the guest agent is connected and the desktop is ready.
    func startDevelopmentTaskIfRequested() async {
        guard let goal = ProcessInfo.processInfo.environment["CC_DEV_TASK"], !goal.isEmpty, !devTaskStarted, let vm else { return }
        devTaskStarted = true
        for _ in 0..<120 {
            if let bridge, await bridge.isConnected,
               case .health(let report)? = try? await bridge.send(.init(vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                                        deadline: Date().addingTimeInterval(10), command: .health)),
               report.isDesktopReady {
                try? await Task.sleep(for: .seconds(3))
                submit(goal)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        transcript.append(ChatItem(role: .system, text: "The virtual Mac did not become ready for the development task."))
    }

    func finishOnboarding() {
        isReady = true
    }

    // MARK: VM

    func loadVM() {
        do {
            let controller = try VirtualMachineController(bundle: bundle)
            controller.onSocketDeviceReady = { [weak self] device in self?.bridge?.attach(to: device) }
            vm = controller
            try connectBridgeIfPaired()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func bootVM() async {
        guard let vm else { return }
        await vm.start()
        if vm.resumedFromSavedState {
            transcript.append(ChatItem(role: .system, text: "Your virtual Mac picked up where you left off."))
        }
    }

    /// Before the app quits: stop work in progress and save the virtual Mac (memory included), so the next
    /// launch resumes it. If saving fails it shuts down cleanly instead, and only as a last resort is it cut off.
    func prepareToQuit() async {
        external?.stop()
        guard let vm else { return }
        for _ in 0..<240 where snapshotActivity != nil || vm.isWorkingOnSnapshots {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if isRunningTask, let runner { await runner.cancel() }
        if externalHolder != nil { await external?.release(note: nil) }
        guard vm.state == .running else { return }

        snapshotActivity = SnapshotActivity(title: "Saving your virtual Mac…", frozenScreen: captureGuestScreen())
        do {
            let available = SnapshotStore.availableCapacity(for: vm.bundle.url)
            guard available >= vm.spaceNeededForMemorySnapshot else {
                throw VMError.notEnoughSpace(needed: vm.spaceNeededForMemorySnapshot, available: available)
            }
            try await vm.suspend()
        } catch {
            snapshotActivity = SnapshotActivity(title: "Shutting down your virtual Mac…", frozenScreen: snapshotActivity?.frozenScreen)
            let bridge = self.bridge
            let vmID = vm.spec.id
            try? await vm.shutDown(viaGuest: bridge.map { bridge in
                { _ = try await bridge.send(.init(vmID: vmID, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                  deadline: Date().addingTimeInterval(15), command: .shutdown)) }
            }, timeout: .seconds(90))
            if vm.state != .stopped { try? await vm.forceStop() }
        }
    }

    /// The bridge exists once the agent has been installed and a pairing token stored.
    func connectBridgeIfPaired() throws {
        guard let vm, let token = try secrets.read(SecretAccount.pairingToken(vmID: vm.spec.id)) else { return }
        let server = BridgeServer(vmID: vm.spec.id, pairingToken: token)
        bridge = server
        if let device = vm.virtualMachine?.socketDevices.first as? VZVirtioSocketDevice {
            server.attach(to: device)
        }
    }

    // MARK: Tasks

    /// Chat input: answers a pending question, or starts a new task.
    func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Attachments go with a new task, not with an answer to the agent's question.
        let startsTask = !(runner != nil && { if case .waitingForUser = phase { true } else { false } }())
        let attached = startsTask && !pendingAttachments.isEmpty
            ? "\n📎 " + pendingAttachments.map(\.lastPathComponent).joined(separator: ", ") : ""
        transcript.append(ChatItem(role: .user, text: text + attached))

        if let runner, case .waitingForUser = phase {
            Task { await runner.answer(text) }
            return
        }
        guard phase.isTerminal || phase == .ready else {
            transcript.append(ChatItem(role: .system, text: "A task is already active. Pause or cancel it first."))
            return
        }
        guard snapshotActivity == nil, vm?.isWorkingOnSnapshots != true else {
            transcript.append(ChatItem(role: .system, text: "Wait until the snapshot is finished, then send the task again."))
            return
        }
        startTask(goal: text)
    }

    private func startTask(goal: String) {
        guard let vm, let bridge else {
            errorMessage = "The virtual Mac is not set up yet."
            return
        }
        let model: any ModelClient
        do {
            model = try makeModelClient(for: modelSettings)
        } catch {
            errorMessage = "The model is not set up: \(error). Choose a model in Settings."
            return
        }
        let attachments = pendingAttachments
        pendingAttachments = []
        let runner = AgentRunner(goal: goal, attachments: attachments, dependencies: .init(
            model: model, guest: bridge, store: store, lease: lease,
            folders: SharedFolders(root: vm.bundle.sharedRoot)))
        self.runner = runner
        tokens = (0, 0)

        Task {
            for await update in runner.updates { apply(update) }
        }
        let external = self.external
        Task {
            // The user's own task comes first: a coding agent holding the virtual Mac gives it up.
            if let holder = externalHolder {
                await external?.release(note: "\(holder) lost control of the virtual Mac to your task.")
            }
            if let blocked = externalBlockedBy {
                await lease.releaseFromUser()
                externalBlockedBy = nil
                transcript.append(ChatItem(role: .system, text: "\(blocked) can take control again after your task."))
            }
            do { try await runner.start() } catch { errorMessage = error.localizedDescription }
        }
    }

    private func apply(_ update: RunnerUpdate) {
        devLog(update)
        switch update {
        case .phase(let phase):
            self.phase = phase
            if case .failed(let reason) = phase { transcript.append(ChatItem(role: .system, text: reason)) }
        case .assistantNote(let text):
            transcript.append(ChatItem(role: .agent, text: text))
        case .action(let name):
            transcript.append(ChatItem(role: .action, text: name))
        case .needsUser(let ask):
            transcript.append(ChatItem(role: .agent, text: "\(ask.question)\n→ \(ask.target)"))
        case .usage(let input, let output):
            tokens = (input, output)
        case .delivered(let files):
            transcript.append(ChatItem(role: .system, text: "Verified results", files: files))
        }
    }

    // MARK: Control (proposal §04: pause, takeover and cancel are different)

    func pause() {
        // ⌘. stops a coding agent too: for it, pausing means the user takes over.
        if externalHolder != nil, !isRunningTask { return takeOver(reason: "you chose Pause") }
        Task { await runner?.pause() }
    }
    func resume() { Task { await runner?.resume() } }
    func cancel() { Task { await runner?.cancel() } }

    /// The user touched the VM screen while the agent held input.
    /// The user takes input control from the agent. `reason` says what triggered it, shown in the chat.
    func takeOver(reason: String = "you chose Take Over") {
        if externalHolder != nil, !isRunningTask {
            Task { await external?.userTookOver(reason: reason) }
            return
        }
        if agentHoldsInput { transcript.append(ChatItem(role: .system, text: "You took over: \(reason). The agent paused.")) }
        Task {
            if let runner { await runner.takeOver() } else { await lease.grantToUser() }
        }
    }

    func returnControl() {
        if externalBlockedBy != nil, !isRunningTask {
            Task { await external?.handBack() }
            return
        }
        Task { await runner?.returnControl() }
    }

    func export(_ file: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: file, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.copyItem(at: file, to: destination)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Host-level control

    /// Grants the guest agent its permissions by operating the guest from the host (onboarding step 4).
    /// The guest password goes from the secret store straight into the guest; it is never shown or logged.
    func grantPermissionsAutomatically() async throws {
        guard let vm, let bridge, let view = guestView else { throw HostControlError.noWindow }
        let vmID = vm.spec.id
        let display = HostDisplay(view: view, guestSize: CGSize(width: vm.spec.displayWidth / 2, height: vm.spec.displayHeight / 2))
        func send(_ command: GuestCommand) async throws -> CommandResult {
            try await bridge.send(.init(vmID: vmID, jobID: nil, leaseToken: nil, observationVersion: nil,
                                        deadline: Date().addingTimeInterval(15), command: command))
        }
        let secrets = self.secrets
        let grant = PermissionGrant(
            display: display,
            prepare: { kind in _ = try await send(.preparePermission(kind)) },
            isGranted: { kind in
                // The agent relaunches after the screen recording grant; until it reconnects, "not yet".
                guard await bridge.isConnected, case .health(let report)? = try? await send(.health) else { return false }
                return kind == .accessibility ? report.accessibilityGranted : report.screenRecordingGranted
            },
            restartAgent: {
                _ = try? await send(.restartAgent)
                // Wait for the old connection to drop and the new agent to pair.
                try await Task.sleep(for: .seconds(2))
                var waited = 0
                while !(await bridge.isConnected), waited < 30 {
                    try await Task.sleep(for: .seconds(1))
                    waited += 1
                }
                try await Task.sleep(for: .seconds(1))
            },
            password: {
                guard let password = try secrets.read(SecretAccount.guestPassword(vmID: vmID)) else {
                    throw HostControlError.gaveUp("The guest password is missing from this Mac (secrets.json in the virtual machine folder).")
                }
                return password
            },
            log: { [weak self] message in self?.onboarding.detail = message.prefix(1).uppercased() + message.dropFirst() })
        try await grant.run()
    }
}
