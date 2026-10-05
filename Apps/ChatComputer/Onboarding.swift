import AppKit
import ChatCore
import GuestBridge
import HostControl
import SwiftUI
import UniformTypeIdentifiers
import VMKit
import Virtualization

/// First-run steps from ROADMAP §3. Each step is resumable: progress is persisted in `VMSpec.stage`.
struct OnboardingState {
    enum Step: Int, CaseIterable {
        case installMacOS, firstBoot, installAgent, grantPermissions, freezeImage, apiKey

        var title: LocalizedStringKey {
            switch self {
            case .installMacOS: "Download and install macOS"
            case .firstBoot: "Set up the guest account"
            case .installAgent: "Install the Chat Computer agent"
            case .grantPermissions: "Allow device control and screen recording"
            case .freezeImage: "Save a clean starting point"
            case .apiKey: "Connect a model"
            }
        }
    }

    var step: Step = .installMacOS
    var progress: Double?
    var detail = ""
    var isWorking = false
    /// A local IPSW to install from instead of downloading one.
    var restoreImage: URL?
}

extension AppModel {
    func resumeOnboarding() {
        guard let spec = try? bundle.loadSpec() else { return }
        onboarding.step = switch spec.stage {
        case .created: .installMacOS
        case .installed: .firstBoot
        case .provisioned: .installAgent
        case .agentInstalled: .grantPermissions
        case .ready: .apiKey
        }
        // These steps happen in (or with) the running guest, so bring it up when setup resumes there.
        if onboarding.step == .grantPermissions {
            onboarding.detail = "Chat Computer can turn these on for you: it clicks in the virtual Mac and types the "
                + "guest password stored on this Mac. You can watch it happen on the left."
            if vm?.state == .stopped { Task { await bootVM() } }
        }
    }

    /// Development: CC_AUTO_ONBOARD=1 runs every setup step in turn, up to connecting a model,
    /// stopping at the first step that does not complete.
    func startAutoOnboardingIfRequested() {
        guard ProcessInfo.processInfo.environment["CC_AUTO_ONBOARD"] == "1", !autoOnboardingStarted else { return }
        autoOnboardingStarted = true
        Task {
            while onboarding.step != .apiKey {
                let step = onboarding.step
                if step == .grantPermissions { await grantPermissionsStep() } else { await runOnboardingStep() }
                guard onboarding.step != step else { break }
            }
        }
    }

    /// Step 4 done by host-level control, then the usual check through the agent.
    func grantPermissionsStep() async {
        onboarding.isWorking = true
        do {
            if vm?.state != .running { await bootVM() }
            var waited = 0
            while !(await bridge?.isConnected ?? false), waited < 60 {
                onboarding.detail = "Waiting for the agent in the virtual Mac to connect…"
                try await Task.sleep(for: .seconds(1))
                waited += 1
            }
            // The next part types and clicks into the virtual Mac from this Mac, which only reaches it while this
            // app is in front: macOS doesn't let a background app take the focus.
            var attention: Int?
            while !NSApp.isActive {
                onboarding.detail = "Click this window to continue: the next step operates the virtual Mac's screen, which only works while Chat Computer is in front."
                // Someone who switched away during setup gets a bouncing Dock icon rather than a silent wait.
                if attention == nil { attention = NSApp.requestUserAttention(.criticalRequest) }
                devLog("onboarding: waiting for the app to be in front")
                try await Task.sleep(for: .seconds(1))
            }
            if let attention { NSApp.cancelUserAttentionRequest(attention) }
            await unlockGuestIfLocked()
            do {
                try await grantPermissionsAutomatically()
            } catch {
                // Screen recording often needs a second pass on a fresh guest: the agent restarts to pick up the
                // permission and may reconnect after the first pass gave up. A second pass has always finished it.
                onboarding.detail = "Trying once more…"
                try await Task.sleep(for: .seconds(3))
                try await grantPermissionsAutomatically()
            }
            onboarding.isWorking = false
            await runOnboardingStep()
        } catch {
            onboarding.isWorking = false
            onboarding.detail = "Automatic setup stopped: \(error)\n\n" + Self.permissionInstructions
        }
    }

    /// The clean starting point should greet the first task with an empty desktop. The agent's first screenshot
    /// makes macOS ask whether it may keep recording the screen: take one now and answer it from the host, so the
    /// answer is part of the saved machine. And System Settings, left open by the permission step, would reopen
    /// at every login.
    func tidyGuestBeforeFreezing() async {
        guard let vm, let bridge, let view = guestView, await bridge.isConnected else { return }
        let display = HostDisplay(view: view, guestSize: CGSize(width: vm.spec.displayWidth / 2, height: vm.spec.displayHeight / 2))
        _ = try? await bridge.send(.init(vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                         deadline: Date().addingTimeInterval(10), command: .screenshot(region: nil)))
        for _ in 0..<5 {
            try? await Task.sleep(for: .seconds(2))
            if await ConsentPrompt.approveIfShown(on: display) {
                devLog("onboarding: answered the screen recording prompt")
                break
            }
        }
        let grant = PermissionGrant(display: display, prepare: { _ in }, isGranted: { _ in true }, restartAgent: {}, password: { "" })
        try? await grant.quitSystemSettings()
    }

    static let permissionInstructions = """
        In the virtual Mac on the left, click the Chat Computer Agent icon in the menu bar, \
        choose Allow Device Control, and turn on ChatComputerAgent under Privacy & Security › \
        Device Control and Data Access. Do the same for screen recording, then click Continue.
        """

    func runOnboardingStep() async {
        onboarding.isWorking = true
        defer { onboarding.isWorking = false }
        do {
            switch onboarding.step {
            case .installMacOS:
                let spec = (try? bundle.loadSpec()) ?? VMSpec(macAddress: VZMACAddress.randomLocallyAdministered().string)
                _ = try await MacOSInstaller(bundle: bundle).install(spec: spec, restoreImage: onboarding.restoreImage) { [weak self] progress in
                    self?.show(progress)
                }
                loadVM()
                onboarding.step = .firstBoot

            case .firstBoot:
                guard let vm else { return }
                // Development: CC_GUEST_PASSWORD sets a known guest password instead of a random one.
                let options = try GuestProvisioner(bundle: bundle, secrets: secrets)
                    .firstBootOptions(spec: vm.spec, password: ProcessInfo.processInfo.environment["CC_GUEST_PASSWORD"])
                try options.validate()
                onboarding.detail = "Starting the virtual Mac and creating the account…"
                await vm.start(provisioning: options)
                try vm.updateSpec { $0.stage = .provisioned }
                onboarding.step = .installAgent

            case .installAgent:
                guard let vm else { return }
                guard let agentApp = Bundle.main.url(forResource: "ChatComputerAgent", withExtension: "app", subdirectory: "GuestAgent") else {
                    throw VMError.bootstrapFailed("ChatComputerAgent.app is missing from the app bundle")
                }
                if vm.state != .running { await vm.start() }
                onboarding.detail = "Waiting for the guest desktop, then installing…"
                let provisioner = GuestProvisioner(bundle: bundle, secrets: secrets)
                do {
                    try await provisioner.installAgent(spec: vm.spec, agentApp: agentApp, subnet: vm.network.ipv4Subnet)
                } catch VMError.guestAddressUnknown {
                    // The guest never came up on the network: restart it once and wait again.
                    devLog("onboarding: guest unreachable after 10 minutes; restarting it")
                    onboarding.detail = "The virtual Mac is not responding; restarting it…"
                    try? await vm.forceStop()
                    await vm.start()
                    onboarding.detail = "Waiting for the guest desktop, then installing…"
                    try await provisioner.installAgent(spec: vm.spec, agentApp: agentApp, subnet: vm.network.ipv4Subnet)
                }
                try connectBridgeIfPaired()
                try vm.updateSpec { $0.stage = .agentInstalled }
                onboarding.step = .grantPermissions

            case .grantPermissions:
                // The user grants these inside the guest (left pane); we only observe the result.
                guard let bridge, let vm else { return }
                if vm.state != .running { await vm.start() }
                // The agent may be restarting to pick up a new permission; give it time to reconnect.
                for _ in 0..<30 where !(await bridge.isConnected) { try await Task.sleep(for: .seconds(1)) }
                guard await bridge.isConnected else {
                    onboarding.detail = "Waiting for the agent in the virtual Mac to connect. Try again in a few seconds."
                    return
                }
                let health = try await bridge.send(.init(vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                         deadline: Date().addingTimeInterval(10), command: .health))
                guard case .health(let report) = health, report.isDesktopReady else {
                    onboarding.detail = "Not granted yet. " + Self.permissionInstructions
                    return
                }
                onboarding.step = .freezeImage

            case .freezeImage:
                guard let vm else { return }
                onboarding.detail = "Tidying up the virtual Mac…"
                await tidyGuestBeforeFreezing()
                onboarding.detail = "Shutting down the virtual Mac…"
                let bridge = self.bridge
                try await vm.shutDown(viaGuest: bridge.map { bridge in
                    { _ = try await bridge.send(.init(vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                      deadline: Date().addingTimeInterval(15), command: .shutdown)) }
                })
                try vm.updateSpec { spec in
                    try DiskStack(bundle: bundle).pushOverlay(spec: &spec)
                    spec.stage = .ready
                }
                loadVM()
                // The protected "Freshly set up" snapshot: restoring it resets the computer.
                try self.vm?.recordInitialSnapshot()
                onboarding.step = .apiKey

            case .apiKey:
                break
            }
            onboarding.detail = ""
            onboarding.progress = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func show(_ progress: MacOSInstaller.Progress) {
        switch progress {
        case .checkingHost: onboarding.detail = "Checking this Mac…"; onboarding.progress = nil
        case .downloading(let fraction): onboarding.detail = "Downloading macOS…"; onboarding.progress = fraction
        case .preparing: onboarding.detail = "Preparing the virtual disk…"; onboarding.progress = nil
        case .installing(let fraction): onboarding.detail = "Installing macOS…"; onboarding.progress = fraction
        case .done: onboarding.progress = nil
        }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Workspace {
            // The guest screen is visible from first boot on, so the permission step happens in place.
            GuestStage(virtualMachine: model.vm?.virtualMachine, aspectRatio: model.guestAspectRatio,
                       onViewReady: { model.guestView = $0 }) {
                GuestPlaceholder(title: "Your virtual Mac will appear here",
                                 detail: model.onboarding.isWorking ? model.onboarding.detail : "",
                                 progress: model.onboarding.isWorking ? model.onboarding.progress : nil)
            }
        } panel: {
            VStack(alignment: .leading, spacing: 16) {
                Text("Set up your Chat Computer").font(.title2.bold())
                ForEach(OnboardingState.Step.allCases, id: \.self) { step in
                    Label(step.title, systemImage: icon(for: step))
                        .foregroundStyle(step == model.onboarding.step ? .primary : .secondary)
                }
                Divider()
                if model.onboarding.step == .apiKey {
                    ModelSettingsForm(onSaved: { model.finishOnboarding() })
                        .scrollContentBackground(.hidden)
                } else {
                    if let progress = model.onboarding.progress { ProgressView(value: progress) }
                    Text(model.onboarding.detail).font(.callout).foregroundStyle(.secondary)
                    if model.onboarding.step == .grantPermissions {
                        // Host-level control does the clicks; the user watches it happen on the left.
                        Button(model.onboarding.isWorking ? "Working…" : "Grant automatically") {
                            Task { await model.grantPermissionsStep() }
                        }
                        .disabled(model.onboarding.isWorking)
                        .keyboardShortcut(.defaultAction)
                        Button("I granted them myself") {
                            Task { await model.runOnboardingStep() }
                        }
                        .buttonStyle(.link)
                        .disabled(model.onboarding.isWorking)
                    } else {
                        Button(model.onboarding.isWorking ? "Working…" : "Continue") {
                            Task { await model.runOnboardingStep() }
                        }
                        .disabled(model.onboarding.isWorking)
                        .keyboardShortcut(.defaultAction)
                        if model.onboarding.step == .installMacOS, !model.onboarding.isWorking {
                            // A restore image downloaded earlier (about 26 GB) saves the download.
                            Button(model.onboarding.restoreImage.map { "Using \($0.lastPathComponent)" } ?? "Use a downloaded restore image…") {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
                                panel.message = "Choose a macOS restore image (.ipsw)"
                                if panel.runModal() == .OK { model.onboarding.restoreImage = panel.url }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                Spacer()
            }
            .padding(24)
        }
        .navigationTitle("Chat Computer")
        .navigationSubtitle("Setting up · step \(model.onboarding.step.rawValue + 1) of \(OnboardingState.Step.allCases.count)")
        .onAppear {
            model.resumeOnboarding()
            model.startAutoOnboardingIfRequested()
        }
    }

    private func icon(for step: OnboardingState.Step) -> String {
        if step.rawValue < model.onboarding.step.rawValue { return "checkmark.circle.fill" }
        return step == model.onboarding.step ? "arrow.right.circle" : "circle"
    }
}
