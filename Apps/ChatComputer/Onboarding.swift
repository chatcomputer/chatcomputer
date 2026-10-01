import ChatCore
import GuestBridge
import SwiftUI
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
            case .grantPermissions: "Allow Accessibility and Screen Recording"
            case .freezeImage: "Save a clean starting point"
            case .apiKey: "Connect a model"
            }
        }
    }

    var step: Step = .installMacOS
    var progress: Double?
    var detail = ""
    var isWorking = false
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
    }

    func runOnboardingStep() async {
        onboarding.isWorking = true
        defer { onboarding.isWorking = false }
        do {
            switch onboarding.step {
            case .installMacOS:
                let spec = (try? bundle.loadSpec()) ?? VMSpec(macAddress: VZMACAddress.randomLocallyAdministered().string)
                _ = try await MacOSInstaller(bundle: bundle).install(spec: spec) { [weak self] progress in
                    self?.show(progress)
                }
                loadVM()
                onboarding.step = .firstBoot

            case .firstBoot:
                guard let vm else { return }
                let options = try GuestProvisioner(bundle: bundle, secrets: secrets).firstBootOptions(spec: vm.spec)
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
                try await GuestProvisioner(bundle: bundle, secrets: secrets).installAgent(spec: vm.spec, agentApp: agentApp)
                try connectBridgeIfPaired()
                try vm.updateSpec { $0.stage = .agentInstalled }
                onboarding.step = .grantPermissions

            case .grantPermissions:
                // The user grants these inside the guest (left pane); we only observe the result.
                guard let bridge, let vm else { return }
                let health = try await bridge.send(.init(vmID: vm.spec.id, jobID: nil, leaseToken: nil, observationVersion: nil,
                                                         deadline: Date().addingTimeInterval(10), command: .health))
                guard case .health(let report) = health, report.isDesktopReady else {
                    onboarding.detail = "Not granted yet. In the virtual Mac, allow ChatComputerAgent under Privacy & Security."
                    return
                }
                onboarding.step = .freezeImage

            case .freezeImage:
                guard let vm else { return }
                onboarding.detail = "Shutting down the virtual Mac…"
                try vm.requestShutdown()
                while vm.state != .stopped { try await Task.sleep(for: .seconds(1)) }
                try vm.updateSpec { spec in
                    try DiskStack(bundle: bundle).pushOverlay(spec: &spec)
                    spec.stage = .ready
                }
                loadVM()
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
    @State private var apiKey = ""

    var body: some View {
        HStack(spacing: 0) {
            // The guest screen is visible from first boot on, so the permission step happens in place.
            VMDisplayView(virtualMachine: model.vm?.virtualMachine, agentHoldsInput: false, onUserIntervention: {})
                .frame(minWidth: 640)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("Set up your Chat Computer").font(.title2.bold())
                ForEach(OnboardingState.Step.allCases, id: \.self) { step in
                    Label(step.title, systemImage: icon(for: step))
                        .foregroundStyle(step == model.onboarding.step ? .primary : .secondary)
                }
                Divider()
                if model.onboarding.step == .apiKey {
                    SecureField("Anthropic API key", text: $apiKey)
                    Button("Save key") {
                        do { try model.secrets.write(apiKey, for: SecretAccount.anthropicAPIKey) } catch { model.errorMessage = error.localizedDescription }
                    }
                    .disabled(apiKey.isEmpty)
                    Text("The key stays in this Mac's Keychain. Screenshots and text from the virtual Mac are sent to Anthropic while a task runs.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if let progress = model.onboarding.progress { ProgressView(value: progress) }
                    Text(model.onboarding.detail).font(.callout).foregroundStyle(.secondary)
                    Button(model.onboarding.isWorking ? "Working…" : "Continue") {
                        Task { await model.runOnboardingStep() }
                    }
                    .disabled(model.onboarding.isWorking)
                    .keyboardShortcut(.defaultAction)
                }
                Spacer()
            }
            .padding(24)
            .frame(width: 360)
        }
        .onAppear { model.resumeOnboarding() }
    }

    private func icon(for step: OnboardingState.Step) -> String {
        if step.rawValue < model.onboarding.step.rawValue { return "checkmark.circle.fill" }
        return step == model.onboarding.step ? "arrow.right.circle" : "circle"
    }
}
