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
    let secrets = KeychainStore()
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

    /// Whether onboarding has finished. Decided once at launch and set by the last onboarding step,
    /// never re-read from disk while the app runs (the VM's stage turns `.ready` one step earlier,
    /// before the model is connected).
    private(set) var isReady = false

    /// The guest display's shape; the left pane always shows it at this ratio.
    var guestAspectRatio: CGFloat {
        guard let spec = vm?.spec, spec.displayHeight > 0 else { return WorkspaceMetrics.guestAspect }
        return CGFloat(spec.displayWidth) / CGFloat(spec.displayHeight)
    }
    var agentHoldsInput: Bool { phase == .running }

    init() {
        importHarnessSecrets()
        isReady = (try? bundle.loadSpec().stage) == .ready
        if bundle.exists { loadVM() }
    }

    func finishOnboarding() {
        isReady = true
    }

    /// A VM set up with the developer harness (`cc-harness vm …`) keeps its guest password and pairing
    /// token in `harness-secrets.json`. When such a bundle is moved to the app's location, take the
    /// secrets into this app's Keychain so onboarding can continue where the harness stopped.
    private func importHarnessSecrets() {
        let file = bundle.url.appendingPathComponent("harness-secrets.json")
        guard let data = try? Data(contentsOf: file),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        do {
            for (account, value) in values where account.hasPrefix("vm.") {
                try secrets.write(value, for: account)
                guard try secrets.read(account) == value else { throw CocoaError(.coderValueNotFound) }
            }
            try FileManager.default.removeItem(at: file)
        } catch {
            errorMessage = "Could not move the harness VM's secrets into the Keychain: \(error)"
        }
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
        await vm?.start()
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
        transcript.append(ChatItem(role: .user, text: text))

        if let runner, case .waitingForUser = phase {
            Task { await runner.answer(text) }
            return
        }
        guard phase.isTerminal || phase == .ready else {
            transcript.append(ChatItem(role: .system, text: "A task is already active. Pause or cancel it first."))
            return
        }
        startTask(goal: text)
    }

    private func startTask(goal: String) {
        guard let vm, let bridge else {
            errorMessage = "The virtual Mac is not set up yet."
            return
        }
        let secrets = self.secrets
        let model = AnthropicClient { try secrets.read(SecretAccount.anthropicAPIKey) }
        let runner = AgentRunner(goal: goal, dependencies: .init(
            model: model, guest: bridge, store: store, lease: lease,
            folders: SharedFolders(root: vm.bundle.sharedRoot)))
        self.runner = runner
        tokens = (0, 0)

        Task {
            for await update in runner.updates { apply(update) }
        }
        Task {
            do { try await runner.start() } catch { errorMessage = error.localizedDescription }
        }
    }

    private func apply(_ update: RunnerUpdate) {
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

    func pause() { Task { await runner?.pause() } }
    func resume() { Task { await runner?.resume() } }
    func cancel() { Task { await runner?.cancel() } }

    /// The user touched the VM screen while the agent held input.
    func takeOver() {
        Task {
            if let runner { await runner.takeOver() } else { await lease.grantToUser() }
        }
    }

    func returnControl() { Task { await runner?.returnControl() } }

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
    /// The guest password goes from the Keychain straight into the guest; it is never shown or logged.
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
                    throw HostControlError.gaveUp("The guest password is missing from the Keychain.")
                }
                return password
            },
            log: { [weak self] message in self?.onboarding.detail = message.prefix(1).uppercased() + message.dropFirst() })
        try await grant.run()
    }
}
