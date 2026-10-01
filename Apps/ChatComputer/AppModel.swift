import AppKit
import ChatCore
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
    private(set) var bridge: BridgeServer?
    private(set) var runner: AgentRunner?

    var transcript: [ChatItem] = []
    private(set) var phase: TaskPhase = .ready
    private(set) var tokens: (input: Int, output: Int) = (0, 0)
    var errorMessage: String?

    var onboarding = OnboardingState()

    var isReady: Bool { (try? bundle.loadSpec().stage) == .ready }
    var agentHoldsInput: Bool { phase == .running }

    init() {
        if bundle.exists { loadVM() }
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
}
