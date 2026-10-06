import AppKit
import BridgeProtocol
import ChatCore
import HostControl
import ImageIO
import GuestBridge
import ModelProxy
import Observation
import Orchestrator
import VMKit
import Virtualization

struct ChatItem: Identifiable, Hashable, Codable {
    /// `status` lines (who controls the Mac, the VM resumed, the agent updated) replace each other; see `appendStatus`.
    enum Role: String, Codable { case user, agent, action, system, status }
    var id = UUID()
    let role: Role
    let text: String
    var files: [URL] = []
    /// The agent's closing words: the task's result, or a question the user has to answer.
    var emphasis: Emphasis?
    /// When it was added; missing in chats saved before 0.9.6.
    var date: Date? = Date()

    enum Emphasis: String, Codable { case result, question }
}

/// What the agent is doing right now, for the live progress line in the chat.
struct TaskProgress: Equatable {
    var turn: Int
    var maxTurns: Int
    /// Set while a request to the model is out.
    var waitingSince: Date?
    var lastAction: String?
}

/// The chat and the unfinished task, saved when the app quits so the next launch continues where it stopped.
struct SavedSession: Codable {
    var transcript: [ChatItem]
    var task: AgentRunner.Checkpoint?
    var inputTokens: Int
    var outputTokens: Int

    static var url: URL {
        VMBundle.defaultLocation.deletingLastPathComponent().appendingPathComponent("session.json")
    }
}

/// App-wide state: the one VM, its bridge, and the current task.
@MainActor
@Observable
final class AppModel {
    let bundle = VMBundle(url: VMBundle.defaultLocation)
    /// Secrets in files: the VM's in its bundle, API keys in Application Support (see `HostSecretStore`).
    let secrets = HostSecretStore(
        machineFile: VMBundle(url: VMBundle.defaultLocation).secretStore().url,
        credentialsFile: VMBundle.defaultLocation.deletingLastPathComponent().appendingPathComponent("credentials.json"))
    let lease = ControlLease()
    /// Every task and its event log, in Application Support/ChatComputer/Tasks.
    let store = FileTaskStore(root: VMBundle.defaultLocation.deletingLastPathComponent().appendingPathComponent("Tasks", isDirectory: true))

    private(set) var vm: VirtualMachineController?
    /// The on-screen VM view; host-level control (`HostDisplay`) reads and drives the guest through it.
    weak var guestView: VZVirtualMachineView?
    private(set) var bridge: BridgeServer?
    private(set) var runner: AgentRunner?

    var transcript: [ChatItem] = []
    private(set) var phase: TaskPhase = .ready
    private(set) var tokens: (input: Int, output: Int) = (0, 0)
    private(set) var progress: TaskProgress?
    /// Of the input tokens, how many the provider served from its prompt cache.
    private(set) var cachedTokens = 0
    var errorMessage: String?
    /// The guest's readiness from the last check (every 5 s while running); nil when not known.
    private(set) var guestReadiness: GuestReadiness?
    /// Set while the guest agent is being replaced with the one bundled in this app.
    private(set) var updatingAgent = false
    private var agentUpdatePolicy = AgentUpdatePolicy()
    private var pausedForSleep = false
    private var lastUnlockAttempt = Date.distantPast

    var onboarding = OnboardingState()

    /// A snapshot being taken or restored, shown over the guest screen (see Snapshots.swift).
    var snapshotActivity: SnapshotActivity?
    var showingSnapshots = false
    var showingSharedFolders = false
    private func emphasizeLastAgentMessage(_ emphasis: ChatItem.Emphasis) {
        guard let index = transcript.lastIndex(where: { $0.role != .action && $0.role != .status }),
              transcript[index].role == .agent else { return }
        transcript[index].emphasis = emphasis
    }

    /// A status line (a coding agent took or released control, restored a snapshot for itself). A coding agent
    /// running many short sessions would otherwise fill the chat with them; only the latest one is kept, as long
    /// as nothing but steps came after it.
    func appendStatus(_ text: String) {
        if let index = transcript.lastIndex(where: { $0.role != .action }), transcript[index].role == .status {
            transcript.remove(at: index)
        }
        transcript.append(ChatItem(role: .status, text: text))
    }

    /// The pane shown in the Settings window.
    var settingsPane: SettingsPane? = .model
    /// Bumped to open the Settings window from code (SwiftUI only opens it from a view).
    var settingsRequest = 0
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
    /// The built-in agent is using the virtual Mac or waiting on an answer to carry on. A task the user paused
    /// doesn't count: coding agents may use the Mac meanwhile, and Continue takes it back (`makeWayForBuiltInTask`).
    var builtInAgentNeedsMac: Bool {
        guard runner != nil else { return false }
        switch phase {
        case .running, .waitingForUser, .waitingExternal: return true
        default: return false
        }
    }

    /// Chat messages (not steps) that arrived while the panel was collapsed.
    var unreadMessageCount: Int { isPanelCollapsed ? max(0, messageCount - seenMessageCount) : 0 }
    private var messageCount: Int { transcript.count { $0.role != .action && $0.role != .status } }

    /// Collapses the panel to the rail, or expands it. The main window animates the change, keeping the guest screen
    /// where it is.
    func setPanelCollapsed(_ collapsed: Bool) {
        guard collapsed != isPanelCollapsed else { return }
        isPanelCollapsed = collapsed
        seenMessageCount = messageCount
        UserDefaults.standard.set(collapsed, forKey: "panelCollapsed")
    }

    init() {
        isReady = (try? bundle.loadSpec().stage) == .ready
        if bundle.exists { loadVM() }
        applyDevelopmentModel()
        restoreSession()
        watchGuest()
        watchHostSleep()
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
    private func devLog(_ update: RunnerUpdate) { devLog("\(update)") }

    /// CC_DEV_LOG only: one line, timestamped. Never pass secrets.
    func devLog(_ message: String) {
        guard let path = ProcessInfo.processInfo.environment["CC_DEV_LOG"], !path.isEmpty else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
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
    /// CC_DEV_CONTINUE=1 continues a task restored from the last session once the guest is ready.
    func continueRestoredTaskIfRequested() async {
        guard ProcessInfo.processInfo.environment["CC_DEV_CONTINUE"] == "1", phase == .paused, let vm, let bridge else { return }
        for _ in 0..<120 {
            if await bridge.isConnected,
               case .health(let report)? = try? await bridge.send(.init(vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                                        deadline: Date().addingTimeInterval(10), command: .health)),
               report.isDesktopReady {
                resume()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

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
            appendStatus("Your virtual Mac picked up where you left off.")
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
        // An unfinished task is paused and saved with the chat; the next launch offers to continue it.
        if isRunningTask, let runner, phase == .running { await runner.pause() }
        await persistSession()
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
    /// Returns false when the message was not taken (a task is running, a snapshot is in progress).
    @discardableResult
    func submit(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let runner, case .waitingForUser = phase {
            transcript.append(ChatItem(role: .user, text: text))
            Task { await runner.answer(text) }
            return true
        }
        // A running task keeps going; the message stays in the field rather than vanishing into the chat.
        guard phase != .running, !{ if case .waitingExternal = phase { true } else { false } }() else {
            errorMessage = "The agent is working on a task. Pause or cancel it before starting another."
            return false
        }
        guard snapshotActivity == nil, vm?.isWorkingOnSnapshots != true else {
            errorMessage = "Wait until the snapshot is finished, then send the task again."
            return false
        }
        // Attachments go with a new task, not with an answer to the agent's question.
        let attached = pendingAttachments.isEmpty ? "" : "\n📎 " + pendingAttachments.map(\.lastPathComponent).joined(separator: ", ")
        transcript.append(ChatItem(role: .user, text: text + attached))
        // A paused or taken-over task gives way to the new one.
        if let runner, !(phase.isTerminal || phase == .ready) {
            let old = runner
            appendStatus("The paused task was cancelled to start this one.")
            Task {
                await old.cancel()
                self.startTask(goal: text)
            }
            return true
        }
        startTask(goal: text)
        return true
    }

    private func startTask(goal: String) {
        guard let vm, let bridge else {
            errorMessage = "The virtual Mac is not set up yet."
            return
        }
        let free = SnapshotStore.availableCapacity(for: vm.bundle.url)
        guard free >= Self.minimumFreeSpaceForTask else {
            transcript.append(ChatItem(role: .system, text: "Only \(free >> 30) GB is free on this Mac. Free up some space first: the virtual Mac writes to its disk while it works, and fails in odd ways when the space runs out."))
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
        let runner = AgentRunner(goal: goal, attachments: attachments, dependencies: Self.withScreenReading(.init(
            model: model, guest: bridge, store: store, lease: lease,
            folders: SharedFolders(root: vm.bundle.sharedRoot))))
        follow(runner)
        tokens = (0, 0)
        Task {
            await makeWayForBuiltInTask()
            await unlockGuestIfLocked()
            do { try await runner.start() } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Lets the runner find text on the guest's screenshots (on-device Vision), for steps such as `save_file`.
    nonisolated static func withScreenReading(_ dependencies: AgentRunner.Dependencies) -> AgentRunner.Dependencies {
        var dependencies = dependencies
        dependencies.locateText = { data, text in
            // Screenshots arrive in the guest's point space; Vision boxes are scaled to the decoded image.
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return await ScreenText.locate(text, inImage: data, width: image.width, height: image.height)
        }
        return dependencies
    }

    /// Shows a runner's updates in the chat.
    private func follow(_ runner: AgentRunner) {
        self.runner = runner
        Task {
            for await update in runner.updates { apply(update) }
        }
    }

    /// The user's own task comes first: a coding agent holding the virtual Mac gives it up.
    private func makeWayForBuiltInTask() async {
        if let holder = externalHolder {
            await external?.release(note: "\(holder) lost control of the virtual Mac to your task.")
        }
        if let blocked = externalBlockedBy {
            await lease.releaseFromUser()
            externalBlockedBy = nil
            transcript.append(ChatItem(role: .system, text: "\(blocked) can take control again after your task."))
        }
    }

    /// Watches the running guest: its readiness every 5 seconds (shown in the window subtitle), the agent's version
    /// (replaced with the bundled one when they differ, see `updateGuestAgent`), and every 20 seconds macOS's
    /// periodic "keep bypassing the private window picker?" prompt, which would otherwise cover the guest's screen
    /// (see `ConsentPrompt`).
    private func watchGuest() {
        Task { [weak self] in
            var tick = 0
            while true {
                try? await Task.sleep(for: .seconds(5))
                tick += 1
                guard let self else { return }
                guard self.isReady, let vm = self.vm, vm.state == .running, self.snapshotActivity == nil,
                      !vm.isWorkingOnSnapshots, !self.updatingAgent, let bridge = self.bridge else {
                    if self.vm?.state != .running { self.guestReadiness = nil }
                    continue
                }
                let connected = await bridge.isConnected
                var report: HealthReport?
                if connected, case .health(let health)? = try? await bridge.send(.init(
                    vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                    deadline: Date().addingTimeInterval(5), command: .health)) {
                    report = health
                }
                self.guestReadiness = GuestReadiness(connected: connected, report: report)
                // A locked screen (after the guest slept, or this Mac did) is unlocked from the host, at most once a minute.
                if self.guestReadiness == .screenLocked, !self.guestIsBusy,
                   Date().timeIntervalSince(self.lastUnlockAttempt) > 60 {
                    self.lastUnlockAttempt = Date()
                    await self.unlockGuestIfLocked()
                    continue
                }

                if let report, let bundled = Self.bundledAgentVersion,
                   self.agentUpdatePolicy.shouldUpdate(running: report.agentVersion, bundled: bundled, busy: self.guestIsBusy) {
                    await self.updateGuestAgent(from: report.agentVersion, to: bundled)
                    continue
                }

                if tick % 12 == 0 { self.warnIfLowOnSpace(vm) }
                guard tick % 4 == 0, let view = self.guestView, view.window != nil else { continue }
                let display = HostDisplay(view: view, guestSize: CGSize(width: vm.spec.displayWidth / 2, height: vm.spec.displayHeight / 2))
                if await ConsentPrompt.approveIfShown(on: display) {
                    self.transcript.append(ChatItem(role: .system, text: "macOS asked again whether the agent in the virtual Mac may keep recording its screen; Chat Computer answered Allow."))
                }
            }
        }
    }

    /// The Mac going to sleep freezes the virtual Mac mid-step: requests to the model time out and guest commands
    /// pass their deadlines. A running task is paused first, as on quit, and the chat says why; on wake the guest
    /// is checked (and unlocked if needed) and the user continues the task.
    private func watchHostSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hostWillSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hostDidWake() }
        }
    }

    func hostWillSleep() {
        if phase == .running, let runner {
            Task { await runner.pause() }
            transcript.append(ChatItem(role: .system, text: "Your Mac is going to sleep, so the task paused. Press Continue when you are back."))
            pausedForSleep = true
        }
        if let holder = externalHolder {
            Task { await external?.release(note: "\(holder) lost control of the virtual Mac: this Mac went to sleep.") }
        }
        saveSession()
    }

    func hostDidWake() {
        guestReadiness = nil
        Task {
            // The guest needs a moment after the host wakes before it answers.
            try? await Task.sleep(for: .seconds(5))
            await unlockGuestIfLocked()
            if pausedForSleep, phase == .paused {
                transcript.append(ChatItem(role: .system, text: "Your Mac is awake again. Press Continue to carry on with the task."))
            }
            pausedForSleep = false
        }
    }

    static let minimumFreeSpaceForTask: Int64 = 3 << 30
    static let lowSpaceWarning: Int64 = 5 << 30
    private var warnedAboutSpace = false

    /// Once per launch, when the Mac is nearly full: the guest's writes would start failing.
    private func warnIfLowOnSpace(_ vm: VirtualMachineController) {
        let free = SnapshotStore.availableCapacity(for: vm.bundle.url)
        if free < Self.lowSpaceWarning, !warnedAboutSpace {
            warnedAboutSpace = true
            transcript.append(ChatItem(role: .system, text: "This Mac is nearly full (\(free >> 30) GB free). Free up space or delete old snapshots, or the virtual Mac will start failing to save."))
        } else if free >= Self.lowSpaceWarning * 2 {
            warnedAboutSpace = false
        }
    }

    /// A task or a coding agent is using the guest; the agent is not replaced under it.
    private var guestIsBusy: Bool {
        externalHolder != nil || !(phase.isTerminal || phase == .ready || phase == .paused)
    }

    /// The agent shipped inside this app, as "1.0.0 (7)".
    static let bundledAgentVersion: String? = bundledAgent.flatMap(AgentVersion.of(bundle:))

    static var bundledAgent: URL? {
        Bundle.main.url(forResource: "ChatComputerAgent", withExtension: "app", subdirectory: "GuestAgent")
    }

    /// Replaces the guest agent with the bundled one: the app is staged in the bootstrap share, which is shared
    /// only for the update; the agent checks its signature (same team), swaps itself and is restarted by launchd.
    /// Its privacy grants carry over because they belong to the signing identity. Restoring an older snapshot
    /// brings back an older agent, so this runs again then.
    private func updateGuestAgent(from running: String, to bundled: String) async {
        guard let vm, let bridge, let source = Self.bundledAgent else { return }
        updatingAgent = true
        agentUpdatePolicy.began()
        defer { updatingAgent = false }
        var stagedFolder: URL?
        var succeeded = false
        var failure = "the agent did not come back with the new version"
        do {
            stagedFolder = try AgentStaging.stage(source, in: vm.bundle.bootstrapDirectory)
            try await Task.sleep(for: .seconds(4))   // the guest sees new files within a second or two
            let result = try await bridge.send(.init(vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                     deadline: Date().addingTimeInterval(30), command: .updateAgent))
            if case .failure(let error) = result { throw error }
            // The old agent exits; launchd starts the new one, which pairs again.
            try await Task.sleep(for: .seconds(3))
            for _ in 0..<60 {
                if await bridge.isConnected,
                   case .health(let report)? = try? await bridge.send(.init(vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                                            deadline: Date().addingTimeInterval(5), command: .health)) {
                    succeeded = report.agentVersion == bundled
                    if !succeeded { failure = "the agent came back as \(report.agentVersion)" }
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            failure = error.localizedDescription
        }
        devLog("agent update \(running) → \(bundled): \(succeeded ? "ok" : failure)")
        if let stagedFolder { try? FileManager.default.removeItem(at: stagedFolder) }
        agentUpdatePolicy.finished(succeeded: succeeded)
        let text: String
        if succeeded {
            text = "Updated the agent in the virtual Mac from \(running) to \(bundled)."
        } else if agentUpdatePolicy.failures >= AgentUpdatePolicy.maxFailures {
            // A guest that still holds an old view of the installer folder (from an app before 0.9.0 build 12)
            // sees the new agent only after it restarts.
            text = "The agent in the virtual Mac is still \(running) (\(failure)). Restart the virtual Mac (shut it down from its Apple menu, then reopen Chat Computer) to finish updating it."
        } else {
            text = "The agent in the virtual Mac is still \(running) (\(failure)); Chat Computer will try again in a minute."
        }
        appendStatus(text)
    }

    /// If the guest's screen is locked, wakes it and types the guest password from the host.
    /// Returns true if it tried. The password goes from the secret store straight into the guest.
    @discardableResult
    func unlockGuestIfLocked() async -> Bool {
        guard let vm, let bridge, let view = guestView, await bridge.isConnected,
              case .health(let report)? = try? await bridge.send(.init(vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                                       deadline: Date().addingTimeInterval(5), command: .health)),
              report.screenLocked,
              let password = try? secrets.read(SecretAccount.guestPassword(vmID: vm.spec.id)) else { return false }
        let display = HostDisplay(view: view, guestSize: CGSize(width: vm.spec.displayWidth / 2, height: vm.spec.displayHeight / 2))
        // Twice at most: the first key press can go to waking a display that was asleep.
        for _ in 0..<2 {
            try? await GuestUnlock.unlock(on: display, password: password)
            if case .health(let after)? = try? await bridge.send(.init(vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                                      deadline: Date().addingTimeInterval(5), command: .health)),
               !after.screenLocked {
                transcript.append(ChatItem(role: .system, text: "The virtual Mac's screen was locked; Chat Computer unlocked it."))
                return true
            }
        }
        transcript.append(ChatItem(role: .system, text: "The virtual Mac's screen is locked and Chat Computer could not unlock it. Click the screen and type the password from secrets.json, or restart the virtual Mac."))
        return true
    }

    // MARK: Session

    /// Restores the chat and an unfinished task saved when the app last quit. The task comes back paused
    /// (or still waiting for an answer); the VM itself resumes from its saved memory, so the screen matches.
    private func restoreSession() {
        guard let data = try? Data(contentsOf: SavedSession.url),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data) else { return }
        transcript = saved.transcript
        tokens = (saved.inputTokens, saved.outputTokens)
        guard let checkpoint = saved.task, !checkpoint.task.phase.isTerminal, let vm, let bridge,
              let model = try? makeModelClient(for: modelSettings) else { return }
        let runner = AgentRunner(restoring: checkpoint, dependencies: Self.withScreenReading(.init(
            model: model, guest: bridge, store: store, lease: lease, folders: SharedFolders(root: vm.bundle.sharedRoot))))
        follow(runner)
        phase = runner.initialPhase
        let note = if case .waitingForUser = phase {
            "The task from last time is still waiting for your answer."
        } else {
            "The task from last time was paused when Chat Computer quit. Choose Continue to pick it up."
        }
        appendStatus(note)
    }

    func saveSession() {
        Task { await persistSession() }
    }

    /// Writes the chat and the task's checkpoint (0600: it holds the conversation and screenshots).
    func persistSession() async {
        var saved = SavedSession(transcript: transcript, task: nil, inputTokens: tokens.input, outputTokens: tokens.output)
        if let runner {
            let checkpoint = await runner.checkpoint()
            if !checkpoint.task.phase.isTerminal { saved.task = checkpoint }
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let url = SavedSession.url
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".session-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, url.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
    }

    /// Starts a fresh chat. Not while a task is unfinished.
    /// The whole chat as Markdown, steps included, on the clipboard.
    func copyConversation() {
        let text = transcript.map { item -> String in
            switch item.role {
            case .user: "**You:** \(item.text)"
            case .agent: item.text
            case .action: "`\(item.text)`"
            case .system, .status: "_\(item.text)_"
            }
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clearChat() {
        guard !isRunningTask else { return }
        transcript = []
        tokens = (0, 0)
        runner = nil
        phase = .ready
        saveSession()
    }

    private func apply(_ update: RunnerUpdate) {
        devLog(update)
        switch update {
        case .phase(let phase):
            self.phase = phase
            if case .waitingForUser = phase { emphasizeLastAgentMessage(.question) }
            if case .failed(let reason) = phase { transcript.append(ChatItem(role: .system, text: reason)) }
            if phase != .running { progress = nil }
            if phase.isTerminal { saveSession() }
        case .assistantNote(let text):
            transcript.append(ChatItem(role: .agent, text: text))
        case .action(let name):
            transcript.append(ChatItem(role: .action, text: name))
            progress?.lastAction = name
            progress?.waitingSince = nil
        case .thinking(let turn, let maxTurns):
            progress = TaskProgress(turn: turn, maxTurns: maxTurns, waitingSince: Date(), lastAction: nil)
            // Saved once per model turn, so a crash loses at most the turn in progress.
            saveSession()
        case .needsUser(let ask):
            transcript.append(ChatItem(role: .agent, text: "\(ask.question)\n→ \(ask.target)"))
        case .usage(let input, let output, let cached):
            tokens = (input, output)
            cachedTokens = cached
        case .delivered(let files):
            emphasizeLastAgentMessage(.result)
            if !files.isEmpty { transcript.append(ChatItem(role: .system, text: "Verified results", files: files)) }
        case .notice(let text):
            transcript.append(ChatItem(role: .system, text: text))
        }
    }

    // MARK: Control (proposal §04: pause, takeover and cancel are different)

    func pause() {
        // ⌘. stops a coding agent too: for it, pausing means the user takes over.
        if externalHolder != nil, !isRunningTask { return takeOver(reason: "you chose Pause") }
        Task { await runner?.pause() }
    }
    func resume() {
        Task {
            await makeWayForBuiltInTask()
            await runner?.resume()
        }
    }
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
            log: { [weak self] message in
                self?.onboarding.detail = message.prefix(1).uppercased() + message.dropFirst()
                self?.devLog("grant: \(message)")
            })
        try await grant.run()
    }
}
