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
    /// Where the restore image comes from: downloaded by setup, or a file the user downloaded.
    enum ImageSource { case download, local }
    var imageSource: ImageSource = OnboardingState.environmentImage == nil ? .download : .local
    /// The local IPSW to install from. Development: CC_RESTORE_IMAGE sets it for unattended setup.
    var restoreImage: URL? = OnboardingState.environmentImage
    /// What the chosen image turned out to be ("macOS 26 (25G83)"), or why it can't be used.
    var restoreImageNote: String?
    var restoreImageUsable = OnboardingState.environmentImage != nil
    var restoreImageFailed = false
    /// The release the chosen image installs; it decides over the cards.
    var restoreImageRelease: GuestRelease?
    private static let environmentImage = ProcessInfo.processInfo.environment["CC_RESTORE_IMAGE"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    /// The macOS release to install. Development: CC_GUEST_MACOS=26 chooses macOS 26 for unattended setup.
    var guestRelease: GuestRelease = ProcessInfo.processInfo.environment["CC_GUEST_MACOS"] == "26" ? .macOS26 : .macOS27
    /// Why the folder chosen for the data can't be used.
    var dataDirectoryProblem: String?
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

    /// One cancellable host operation for both automatic and manual completion.
    func grantPermissionsStep(automatically: Bool = true) async {
        guard permissionTask == nil, !onboarding.isWorking else { return }
        let task = Task { await performPermissionSetup(automatically: automatically) }
        permissionTask = task
        await task.value
        permissionTask = nil
    }

    func cancelPermissionSetup() {
        permissionTask?.cancel()
    }

    private func performPermissionSetup(automatically: Bool) async {
        onboarding.isWorking = true
        var attention: Int?
        defer {
            onboarding.isWorking = false
            if let attention { NSApp.cancelUserAttentionRequest(attention) }
        }
        recordPermission(automatically ? "automatic-setup-started" : "manual-verification-started")
        do {
            if vm?.state != .running { await bootVM() }
            for _ in 0..<60 {
                try Task.checkCancellation()
                if await bridge?.isConnected == true { break }
                onboarding.detail = "Waiting for the agent in the virtual Mac to connect…"
                try await Task.sleep(for: .seconds(1))
            }
            guard await bridge?.isConnected == true else {
                recordPermission("setup-agent-not-connected")
                throw HostControlError.gaveUp("The guest agent did not connect. Restart the virtual Mac and retry.")
            }
            try await ensureGuestAgentCurrent()
            if !NSApp.isActive { recordPermission("waiting-for-host-focus") }
            while !NSApp.isActive {
                onboarding.detail = "Click this window to continue setting up the virtual Mac."
                if attention == nil { attention = NSApp.requestUserAttention(.criticalRequest) }
                try await Task.sleep(for: .seconds(1))
            }
            recordPermission("host-focused")
            await unlockGuestIfLocked()
            try Task.checkCancellation()
            if automatically { try await grantPermissionsAutomatically() }
            onboarding.isWorking = false
            // Both paths go through health AND real capture verification.
            await runOnboardingStep()
        } catch is CancellationError {
            recordPermission("setup-cancelled")
            onboarding.detail = "Automatic setup stopped. Finish any pending prompt in the virtual Mac, then continue manually. " + Self.permissionInstructions
        } catch {
            recordPermission("setup-failed")
            devLog("onboarding: grantPermissions failed: \(error)")
            onboarding.detail = "Setup stopped: \(error)\n\n" + Self.permissionInstructions
        }
    }

    /// macOS 26: Setup Assistant done from this Mac (account, the least sharing choices), then SSH and automatic
    /// login turned on, so the agent installs as on macOS 27. It types and clicks into the guest, which works only
    /// while this app is in front.
    private func walkSetupAssistant(_ vm: VirtualMachineController) async throws {
        var waited = 0
        while guestView?.window == nil, waited < 30 {
            try await Task.sleep(for: .seconds(1))
            waited += 1
        }
        guard let view = guestView else { throw VMError.bootstrapFailed("the virtual Mac's screen is not showing") }
        var attention: Int?
        while !NSApp.isActive {
            onboarding.detail = "Click this window to continue: setting up macOS 26 operates the virtual Mac's screen, which only works while Chat Computer is in front."
            if attention == nil { attention = NSApp.requestUserAttention(.criticalRequest) }
            try await Task.sleep(for: .seconds(1))
        }
        if let attention { NSApp.cancelUserAttentionRequest(attention) }
        onboarding.detail = "Setting up macOS 26 and creating the account…"
        let display = HostDisplay(view: view, guestSize: CGSize(width: vm.spec.displayWidth / 2, height: vm.spec.displayHeight / 2))
        let secrets = self.secrets
        let id = vm.spec.id
        let assistant = SetupAssistant(display: display, fullName: vm.spec.name, username: vm.spec.guestUsername,
                                       password: {
                                           guard let password = try secrets.read(SecretAccount.guestPassword(vmID: id)) else {
                                               throw VMError.bootstrapFailed("guest password missing from secrets.json")
                                           }
                                           return password
                                       },
                                       log: { [weak self] in self?.devLog("onboarding: \($0)") })
        try await assistant.run()
    }

    /// A clean baseline must contain verified screen capture, not merely TCC flags.
    func tidyGuestBeforeFreezing() async throws {
        guard let vm, let view = guestView else { throw HostControlError.noWindow }
        let display = HostDisplay(view: view, guestSize: CGSize(width: vm.spec.displayWidth / 2, height: vm.spec.displayHeight / 2))
        let grant = PermissionGrant(display: display, prepare: { _ in }, isGranted: { _ in true }, restartAgent: {}, password: { "" })
        try await grant.quitSystemSettings()
        try await ensureGuestCaptureVerified()
    }

    static let permissionInstructions = """
        In the virtual Mac on the left, click the Chat Computer Agent icon in the menu bar, \
        choose Allow Device Control, and turn on ChatComputerAgent under Privacy & Security › \
        Device Control and Data Access. Do the same for screen recording, then click Continue.
        """

    func runOnboardingStep() async {
        guard !onboarding.isWorking else { return }
        onboarding.isWorking = true
        defer { onboarding.isWorking = false }
        do {
            switch onboarding.step {
            case .installMacOS:
                // From here on the data stays in this folder, for every process that looks for it.
                if !DataDirectory.isOverridden { DataDirectory.save(dataDirectory) }
                var spec = (try? bundle.loadSpec()) ?? VMSpec(macAddress: VZMACAddress.randomLocallyAdministered().string)
                // The choice holds until the image is downloaded; a local image decides it in the installer.
                if spec.stage == .created { spec.guestRelease = onboarding.guestRelease }
                _ = try await MacOSInstaller(bundle: bundle).install(spec: spec, restoreImage: onboarding.imageSource == .local ? onboarding.restoreImage : nil) { [weak self] progress in
                    self?.show(progress)
                }
                loadVM()
                onboarding.step = .firstBoot

            case .firstBoot:
                guard let vm else { return }
                // Development: CC_GUEST_PASSWORD sets a known guest password instead of a random one.
                let options = try GuestProvisioner(bundle: bundle, secrets: secrets)
                    .firstBootOptions(spec: vm.spec, password: ProcessInfo.processInfo.environment["CC_GUEST_PASSWORD"])
                if vm.spec.release.supportsFirstBootProvisioning {
                    try options.validate()
                    onboarding.detail = "Starting the virtual Mac and creating the account…"
                    await vm.start(provisioning: options)
                } else {
                    // macOS 26 ignores the first-boot account options: walk Setup Assistant from this Mac instead.
                    onboarding.detail = "Starting the virtual Mac…"
                    if vm.state != .running { await vm.start() }
                    try await walkSetupAssistant(vm)
                }
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
                let needsSetupAssistant = vm.spec.release == .macOS26
                do {
                    try await provisioner.installAgent(spec: vm.spec, agentApp: agentApp, subnet: vm.network.ipv4Subnet,
                                                       waitMinutes: needsSetupAssistant ? 1 : 10)
                } catch VMError.guestAddressUnknown {
                    if needsSetupAssistant {
                        // A previous interrupted Terminal step can leave both SSH
                        // and automatic login off. Resume with the saved password;
                        // another cold boot alone cannot turn those services on.
                        devLog("onboarding: guest SSH unavailable; verifying macOS 26 bootstrap again")
                        onboarding.detail = "Remote Login did not start. Checking the virtual Mac's setup again…"
                        try await walkSetupAssistant(vm)
                    } else {
                        devLog("onboarding: guest unreachable after 10 minutes; restarting it")
                        onboarding.detail = "The virtual Mac is not responding; restarting it…"
                        try? await vm.forceStop()
                        await vm.start()
                    }
                    onboarding.detail = "Waiting for the guest desktop, then installing…"
                    try await provisioner.installAgent(spec: vm.spec, agentApp: agentApp, subnet: vm.network.ipv4Subnet)
                }
                try connectBridgeIfPaired()
                try vm.updateSpec { $0.stage = .agentInstalled }
                onboarding.step = .grantPermissions

            case .grantPermissions:
                // A manual grant still needs health and actual pixel verification.
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
                recordPermission("permissions-preflight-passed", guest: report.permissionDiagnostics)
                onboarding.detail = "Checking that the agent can capture the virtual Mac…"
                try await tidyGuestBeforeFreezing()
                try Task.checkCancellation()
                onboarding.step = .freezeImage

            case .freezeImage:
                guard let vm else { return }
                onboarding.detail = "Tidying up the virtual Mac…"
                try await tidyGuestBeforeFreezing()
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
            // Logged as well: the alert is the only other trace, and an unattended setup has no one to read it.
            recordPermission(error is CancellationError ? "onboarding-cancelled" : "onboarding-step-failed")
            devLog("onboarding: \(onboarding.step) failed: \(error)")
            onboarding.detail = error is CancellationError ? "Setup stopped. You can finish permissions manually, then continue." : "Setup stopped: \(error.localizedDescription)"
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
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

/// The setup steps, in the main window's right-hand panel until the virtual Mac is ready. The guest screen on the
/// left is the window's own `GuestStageView`, visible from first boot on, so the permission step happens in place.
struct OnboardingPanel: View {
    @State private var includeGuestScreen = false
    @Environment(AppModel.self) private var model

    var body: some View {
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
                        Task { await model.grantPermissionsStep(automatically: false) }
                    }
                    .buttonStyle(.link)
                    .disabled(model.onboarding.isWorking)
                } else {
                    if model.onboarding.step == .installMacOS, !model.onboarding.isWorking {
                        ReleaseChoice(selection: Bindable(model).onboarding.guestRelease)
                        ImageSourceChoice()
                        if !model.bundle.exists, !DataDirectory.isOverridden { DataLocationChoice() }
                    }
                    Button(model.onboarding.isWorking ? "Working…" : "Continue") {
                        Task { await model.runOnboardingStep() }
                    }
                    .disabled(model.onboarding.isWorking || !model.canStartInstall)
                    .keyboardShortcut(.defaultAction)
                }
            }
            if model.permissionTask != nil {
                Button("Stop automatic setup") { model.cancelPermissionSetup() }
            }
            if model.onboarding.step == .grantPermissions || model.onboarding.step == .freezeImage {
                Toggle("Include the current guest screen in diagnostics", isOn: $includeGuestScreen)
                    .font(.caption)
                Text("The optional image can contain your files and screen content. Nothing is uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Export Diagnostics…") {
                    Task { await Diagnostics.export(model, includeGuestScreen: includeGuestScreen) }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

extension AppModel {
    /// Step 1 can start once the image it needs is settled: setup downloads one, or the chosen file checked out.
    var canStartInstall: Bool {
        onboarding.step != .installMacOS || onboarding.imageSource == .download || onboarding.restoreImageUsable
    }

    /// Asks for a restore image the user downloaded, checks that this Mac can install it, and selects its release.
    func chooseRestoreImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        panel.message = "Choose a macOS restore image (.ipsw)"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onboarding.restoreImage = url
        onboarding.restoreImageUsable = false
        onboarding.restoreImageRelease = nil
        onboarding.restoreImageFailed = false
        onboarding.restoreImageNote = "Checking the image…"
        Task {
            do {
                let image = try await MacOSInstaller.describeImage(at: url)
                guard onboarding.restoreImage == url else { return }
                onboarding.guestRelease = image.release
                onboarding.restoreImageRelease = image.release
                onboarding.restoreImageUsable = true
                onboarding.restoreImageNote = "\(image.release.title) (\(image.build))"
            } catch {
                guard onboarding.restoreImage == url else { return }
                onboarding.restoreImageFailed = true
                onboarding.restoreImageNote = "This file can't be used: \(error.localizedDescription)"
            }
        }
    }

    /// Asks where to keep the app's data instead of the default folder.
    func chooseDataDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Chat Computer keeps the virtual Mac, its snapshots, your chats and API keys"
        panel.directoryURL = dataDirectory.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try useDataDirectory(DataDirectory.folder(forChoice: url))
            onboarding.dataDirectoryProblem = nil
        } catch {
            onboarding.dataDirectoryProblem = error.localizedDescription
        }
    }

    /// Machine › Show Restore Image in Finder: the image the machine was installed from (about 20–27 GB, kept for
    /// reinstalling), else the file chosen for setup, else the machine's folder.
    func revealRestoreImage() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: bundle.restoreImageURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([bundle.restoreImageURL])
        } else if let chosen = onboarding.restoreImage, fileManager.fileExists(atPath: chosen.path) {
            NSWorkspace.shared.activateFileViewerSelecting([chosen])
        } else if fileManager.fileExists(atPath: bundle.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([bundle.url])
        } else {
            NSSound.beep()
        }
    }
}

/// Where the restore image comes from: setup downloads it, or the user downloads it (a browser or download
/// manager can pause and resume) and chooses the file.
private struct ImageSourceChoice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let onboarding = model.onboarding
        VStack(alignment: .leading, spacing: 8) {
            Text("Restore image").font(.headline)
            Picker("Restore image", selection: $model.onboarding.imageSource) {
                Text("Download it during setup").tag(OnboardingState.ImageSource.download)
                Text("Use one I downloaded").tag(OnboardingState.ImageSource.local)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if onboarding.imageSource == .local {
                HStack(spacing: 8) {
                    Button(onboarding.restoreImage == nil ? "Choose…" : "Choose Another…") { model.chooseRestoreImage() }
                    if let image = onboarding.restoreImage {
                        Text(image.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                    }
                }
                if let note = onboarding.restoreImageNote {
                    Text(note).font(.callout)
                        .foregroundStyle(onboarding.restoreImageFailed ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let imageRelease = onboarding.restoreImageRelease, imageRelease != onboarding.guestRelease {
                    Text("This image installs \(imageRelease.title); choose another file for \(onboarding.guestRelease.title).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if onboarding.restoreImage == nil || !onboarding.restoreImageUsable {
                    Link("Download \(onboarding.guestRelease.title) from Apple",
                         destination: MacOSInstaller.downloadURL(for: onboarding.guestRelease))
                        .font(.callout)
                    Text("Then choose the .ipsw file here.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Where the virtual Mac and the rest of the app's data are kept: `~/.chatcomputer` unless the user picks another
/// folder, for instance on a bigger disk. Chosen once, before anything is downloaded.
private struct DataLocationChoice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let free = SnapshotStore.availableCapacity(for: model.dataDirectory) >> 30
        VStack(alignment: .leading, spacing: 8) {
            Text("Location").font(.headline)
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(abbreviated(model.dataDirectory.path)).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Change…") { model.chooseDataDirectory() }
            }
            Text("Holds the virtual Mac, its snapshots, your chats and API keys. Needs about 60 GB; \(free) GB free on this disk.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = model.onboarding.dataDirectoryProblem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The macOS release for the virtual Mac, as two cards: chosen once, before the download.
private struct ReleaseChoice: View {
    @Binding var selection: GuestRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("macOS version").font(.headline)
            card(.macOS27, title: "macOS 27", badge: "Recommended",
                 detail: "The current release. About 27 GB to download, ready in about 10 minutes.")
            card(.macOS26, title: "macOS 26", badge: nil,
                 detail: "For testing on the previous release. About 20 GB, ready in about 14 minutes: Chat Computer walks through Setup Assistant for you.")
        }
    }

    private func card(_ release: GuestRelease, title: String, badge: String?, detail: String) -> some View {
        let selected = selection == release
        return Button { selection = release } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.body.weight(.semibold))
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + (badge.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
