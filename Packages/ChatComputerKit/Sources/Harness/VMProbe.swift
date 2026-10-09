#if os(macOS)
import BridgeProtocol
import ChatCore
import AppKit
import Foundation
import GuestBridge
import HostControl
import ImageIO
import Virtualization
import VMKit

/// Technical probes from ROADMAP §4 (P1, P3, P5, P6) run headless against a dedicated bundle.
///
///     cc-harness vm install                       P1a: IPSW → installed disk
///     cc-harness vm up [options]                  boot and run checks, then stop or suspend
///         --provision                             first boot with VZMacGuestProvisioningOptions (P1b)
///         --agent PATH                            install ChatComputerAgent.app over SSH (P1c)
///         --bridge                                vsock handshake, health and latency (P3)
///         --screenshot                            one screenshot through the agent (P6)
///         --update-agent                          send the agent in Shared/bootstrap to the guest (self-update)
///         --input-test N                          drive TextEdit and a save dialog through the agent N times and
///                                                 compare the saved file with what was typed (driver reliability)
///         --window                                show the VM screen in a window (for manual steps)
///         --console DIR                           operate the guest from the host until `done` (see GuestConsole)
///         --wait-ready                            poll health until Accessibility + Screen Recording are granted
///         --hold SECONDS                          keep running before shutdown (default 0)
///         --suspend                               save state instead of shutting down; next `up` restores
///     cc-harness vm snapshot-test                 take, restore and reset snapshots on a paired VM (SnapshotTest)
///     cc-harness vm regress [--model p:proto:model] [--runs N] [--only ids]  fixed task set (scripts/regress)
///     cc-harness vm share-test                    change shared folders while the VM runs and watch the agent (ShareTest)
///     cc-harness vm status                        bundle stage and files
///
/// The bundle lives at $CC_VM_BUNDLE or Harness.vm in the data folder (`DataDirectory`).
/// Secrets are in the bundle's 0600 `secrets.json`, the same file the app uses.
@MainActor
enum VMProbe {
    static var bundle: VMBundle {
        let path = ProcessInfo.processInfo.environment["CC_VM_BUNDLE"]
        return VMBundle(url: path.map { URL(fileURLWithPath: $0) }
            ?? DataDirectory.current.appendingPathComponent("Harness.vm", isDirectory: true))
    }

    static func run(arguments: [String]) async -> Int32 {
        do {
            switch arguments.first {
            case "install": try await install()
            case "up": try await up(Options(Array(arguments.dropFirst())))
            case "status": try status()
            case "selftest": try selftest()
            case "snapshot-test": try await SnapshotTest.run()
            case "share-test": try await ShareTest.run()
            case "regress": try await Regress.run(arguments: Array(arguments.dropFirst()))
            default:
                print("usage: cc-harness vm install | up [--provision] [--agent PATH] [--bridge] [--screenshot] [--hold N] [--suspend] | snapshot-test | share-test | status")
                return 2
            }
            return 0
        } catch {
            log("FAILED: \(error)")
            return 1
        }
    }

    struct Options {
        var provision = false
        var agent: URL?
        var bridge = false
        var screenshot = false
        var hold: Double = 0
        var suspend = false
        var window = false
        var waitReady = false
        var console: URL?
        var inputTests = 0
        var updateAgent = false
        var agentConsole: URL?
        /// macOS 26: walk Setup Assistant from the host (`HostControl.SetupAssistant`), saving each screen here.
        var setupAssistant: URL?

        init(_ arguments: [String]) {
            var iterator = arguments.makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case "--provision": provision = true
                case "--agent": agent = iterator.next().map { URL(fileURLWithPath: $0) }
                case "--bridge": bridge = true
                case "--screenshot": screenshot = true; bridge = true
                case "--hold": hold = iterator.next().flatMap(Double.init) ?? 0
                case "--suspend": suspend = true
                case "--window": window = true
                case "--agent-console": agentConsole = iterator.next().map { URL(fileURLWithPath: $0) }; bridge = true
                case "--update-agent": updateAgent = true; bridge = true
                case "--input-test": inputTests = iterator.next().flatMap(Int.init) ?? 3; bridge = true
                case "--console": console = iterator.next().map { URL(fileURLWithPath: $0) }; window = true
                case "--wait-ready": waitReady = true; bridge = true
                case "--setup-assistant": setupAssistant = iterator.next().map { URL(fileURLWithPath: $0) }; window = true
                default: print("ignoring unknown option \(argument)")
                }
            }
        }
    }

    // MARK: P1a install

    static func install() async throws {
        let bundle = self.bundle
        try bundle.create()
        // Reuse an IPSW downloaded for the app's own bundle, or $CC_IPSW.
        let shared = ProcessInfo.processInfo.environment["CC_IPSW"].map { URL(fileURLWithPath: $0) }
            ?? VMBundle(url: VMBundle.defaultLocation).restoreImageURL
        let restoreImage = FileManager.default.fileExists(atPath: shared.path) ? shared : nil
        let spec = (try? bundle.loadSpec()) ?? VMSpec(macAddress: VZMACAddress.randomLocallyAdministered().string)
        let started = Date()
        var lastReported = -1
        let installed = try await MacOSInstaller(bundle: bundle).install(spec: spec, restoreImage: restoreImage) { progress in
            switch progress {
            case .installing(let fraction):
                let percent = Int(fraction * 100)
                if percent / 5 != lastReported / 5 { lastReported = percent; log("installing \(percent)%") }
            case .downloading(let fraction):
                let percent = Int(fraction * 100)
                if percent / 5 != lastReported / 5 { lastReported = percent; log("downloading \(percent)%") }
            default:
                log("\(progress)")
            }
        }
        log("installed \(installed.restoreImageBuild ?? "?") in \(elapsed(since: started)); disk: \(diskUsage(bundle.baseDiskURL))")
    }

    // MARK: Boot and checks

    static func up(_ options: Options) async throws {
        let bundle = self.bundle
        let secrets = bundle.secretStore()
        let controller = try VirtualMachineController(bundle: bundle)
        let spec = controller.spec
        log("spec: stage=\(spec.stage.rawValue) cpu=\(spec.cpuCount) mem=\(spec.memoryBytes >> 30)GB display=\(spec.displayWidth)x\(spec.displayHeight) overlays=\(spec.overlayCount)")

        var bridge: BridgeServer?
        if options.bridge, let token = try secrets.read(SecretAccount.pairingToken(vmID: spec.id)) {
            bridge = BridgeServer(vmID: spec.id, pairingToken: token, log: { message in Task { @MainActor in log("bridge: \(message)") } })
        }
        controller.onSocketDeviceReady = { device in bridge?.attach(to: device) }

        let provisioning = options.provision
            ? try GuestProvisioner(bundle: bundle, secrets: secrets).firstBootOptions(spec: spec) : nil
        let restoring = !options.provision && FileManager.default.fileExists(atPath: bundle.savedStateURL.path)
        let bootStarted = Date()
        await controller.start(provisioning: provisioning)
        guard controller.state == .running else { throw ProbeError("start failed: \(controller.state)") }
        log("\(restoring ? "restored" : "started") in \(elapsed(since: bootStarted))")
        if options.provision { try controller.updateSpec { $0.stage = .provisioned } }
        var console: GuestConsole?
        if options.window, let machine = controller.virtualMachine {
            let (view, window) = showWindow(machine, spec: spec)
            if let directory = options.setupAssistant {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if try secrets.read(SecretAccount.guestPassword(vmID: spec.id)) == nil {
                    _ = try GuestProvisioner(bundle: bundle, secrets: secrets).firstBootOptions(spec: spec)
                }
                let display = HostDisplay(view: view, guestSize: CGSize(width: spec.displayWidth / 2, height: spec.displayHeight / 2))
                var shot = 0
                let assistant = SetupAssistant(
                    display: display, fullName: spec.name, username: spec.guestUsername,
                    password: { try secrets.read(SecretAccount.guestPassword(vmID: spec.id)) ?? "" },
                    log: { log($0) },
                    trace: { page, image in
                        shot += 1
                        let url = directory.appendingPathComponent(String(format: "%03d-%@.png", shot, page.replacingOccurrences(of: " ", with: "_")))
                        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
                        CGImageDestinationAddImage(destination, image, nil)
                        CGImageDestinationFinalize(destination)
                    })
                let walkStarted = Date()
                try await assistant.run()
                log("setup assistant finished in \(elapsed(since: walkStarted))")
                try controller.updateSpec { $0.stage = .provisioned }
            }
            if let directory = options.console {
                console = GuestConsole(view: view, window: window, directory: directory)
                console?.guestSize = CGSize(width: spec.displayWidth / 2, height: spec.displayHeight / 2)
            }
        }

        if let agent = options.agent {
            log("waiting for guest network and SSH…")
            let sshStarted = Date()
            try await GuestProvisioner(bundle: bundle, secrets: secrets).installAgent(spec: controller.spec, agentApp: agent, subnet: controller.network.ipv4Subnet)
            log("guest subnet: \(controller.network.ipv4Subnet.map { String(format: "%08x/%08x", $0.address, $0.mask) } ?? "unknown")")
            log("agent installed over SSH in \(elapsed(since: sshStarted)) (\(elapsed(since: bootStarted)) since boot)")
            try controller.updateSpec { $0.stage = .agentInstalled }
            if bridge == nil, options.bridge, let token = try secrets.read(SecretAccount.pairingToken(vmID: spec.id)) {
                let server = BridgeServer(vmID: spec.id, pairingToken: token, log: { message in Task { @MainActor in log("bridge: \(message)") } })
                bridge = server
                if let device = controller.virtualMachine?.socketDevices.first as? VZVirtioSocketDevice { server.attach(to: device) }
            }
        }

        if !options.bridge { try await console?.serve() }
        if options.bridge {
            guard let bridge else { throw ProbeError("no pairing token yet; run with --agent first") }
            try await probeBridge(bridge, vmID: spec.id, bootStarted: bootStarted)
            try await console?.serve()
            if options.updateAgent {
                // The installer is only shared while an update needs it; give the guest a moment to see it.
                controller.setBootstrapAttached(true)
                try await Task.sleep(for: .seconds(3))
                defer { controller.setBootstrapAttached(false) }
                let result = try await bridge.send(envelope(spec.id, .updateAgent))
                log("update agent: \(result)")
                if result == .ok {
                    try await Task.sleep(for: .seconds(3))
                    while await !bridge.isConnected { try await Task.sleep(for: .milliseconds(300)) }
                    log("updated agent reconnected")
                }
            }
            if options.waitReady { try await waitUntilReady(bridge, vmID: spec.id) }
            if options.screenshot { try await probeScreenshot(bridge, vmID: spec.id) }
            if let directory = options.agentConsole {
                try await AgentConsole.serve(bridge, vmID: spec.id, directory: directory)
            }
            if options.inputTests > 0 {
                try await InputTest.run(bridge, vmID: spec.id, outbox: bundle.sharedRoot.appendingPathComponent("outbox"),
                                        rounds: options.inputTests)
            }
        }

        if options.hold > 0 {
            log("holding for \(Int(options.hold))s")
            try await Task.sleep(for: .seconds(options.hold))
        }

        if options.suspend {
            let saveStarted = Date()
            try await controller.suspend()
            log("suspended in \(elapsed(since: saveStarted)); state file \(diskUsage(bundle.savedStateURL))")
        } else {
            try await shutdown(controller, console: console, bridge: bridge)
        }
    }

    /// P3: pairing, health, round-trip latency, and the guest-side lease check.
    static func probeBridge(_ bridge: BridgeServer, vmID: UUID, bootStarted: Date) async throws {
        log("waiting for the guest agent to connect over vsock…")
        let deadline = Date().addingTimeInterval(300)
        while await !bridge.isConnected {
            guard Date() < deadline else { throw ProbeError("agent did not connect within 300s") }
            try await Task.sleep(for: .milliseconds(200))
        }
        log("agent paired \(elapsed(since: bootStarted)) after boot")

        func envelope(_ command: GuestCommand) -> CommandEnvelope { VMProbe.envelope(vmID, command) }

        let health = try await bridge.send(envelope(.health))
        log("health: \(health)")
        let capabilities = try await bridge.send(envelope(.capabilities))
        log("capabilities: \(capabilities)")

        var samples: [Double] = []
        for _ in 0..<50 {
            let start = ContinuousClock.now
            _ = try await bridge.send(envelope(.health))
            let duration = ContinuousClock.now - start
            samples.append(Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
        }
        samples.sort()
        log(String(format: "health round trip over vsock: p50 %.2f ms, p95 %.2f ms, max %.2f ms",
                   samples[samples.count / 2], samples[samples.count * 95 / 100], samples.last ?? 0))

        // Input without the lease must be refused by the guest itself.
        let refused = try await bridge.send(envelope(.perform(.mouseMove(to: ScreenPoint(x: 10, y: 10)))))
        log("input without lease: \(refused)")
    }

    static func envelope(_ vmID: UUID, _ command: GuestCommand, lease: UUID? = nil) -> CommandEnvelope {
        CommandEnvelope(vmID: vmID, jobID: nil, leaseToken: lease, observationVersion: nil,
                        deadline: Date().addingTimeInterval(30), command: command)
    }

    /// Onboarding step 6: the user allows ChatComputerAgent in the guest's Privacy & Security settings.
    static func waitUntilReady(_ bridge: BridgeServer, vmID: UUID) async throws {
        var announced = false
        while true {
            guard case .health(let report) = try await bridge.send(envelope(vmID, .health)) else { throw ProbeError("no health report") }
            if report.isDesktopReady {
                log("desktop ready: \(report)")
                return
            }
            if !announced {
                log("waiting for permissions in the guest: accessibility=\(report.accessibilityGranted) screenRecording=\(report.screenRecordingGranted) aqua=\(report.hasAquaSession) locked=\(report.screenLocked) shares=\(report.sharedFoldersMounted)")
                announced = true
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// P6 (capture only): one full screenshot and one zoom through the native driver.
    static func probeScreenshot(_ bridge: BridgeServer, vmID: UUID) async throws {
        for (name, region) in [("full", nil), ("zoom", ScreenRect(x0: 0, y0: 0, x1: 320, y1: 200))] as [(String, ScreenRect?)] {
            let started = ContinuousClock.now
            let result = try await bridge.send(envelope(vmID, .screenshot(region: region)))
            guard case .screenshot(let shot) = result else {
                log("screenshot \(name): \(result)")
                continue
            }
            let file = bundle.url.appendingPathComponent("probe-\(name).png")
            try shot.imageData.write(to: file)
            log("screenshot \(name) \(shot.width)x\(shot.height) \(shot.imageData.count / 1024) KB in \(ContinuousClock.now - started) → \(file.path)")
        }
    }

    static var window: NSWindow?

    @discardableResult
    static func showWindow(_ machine: VZVirtualMachine, spec: VMSpec) -> (VZVirtualMachineView, NSWindow) {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = false
        let size = NSSize(width: spec.displayWidth / 2, height: spec.displayHeight / 2)
        // A non-activating panel can become key (so the view receives keys) without the app
        // being frontmost; a background app cannot activate itself on macOS 14+.
        let window = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        window.becomesKeyOnlyIfNeeded = false
        window.title = "cc-harness — \(spec.name)"
        window.contentView = view
        window.contentAspectRatio = size
        window.center()
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        self.window = window
        return (view, window)
    }

    static func shutdown(_ controller: VirtualMachineController, console: GuestConsole? = nil, bridge: BridgeServer? = nil) async throws {
        if let bridge, await bridge.isConnected {
            let started = Date()
            log("shutting down via the guest agent…")
            do {
                try await controller.shutDown(viaGuest: {
                    _ = try await bridge.send(envelope(controller.spec.id, .shutdown))
                }, timeout: .seconds(120))
                log("stopped cleanly in \(elapsed(since: started))")
                return
            } catch {
                log("agent shutdown failed: \(error)")
            }
        }
        log("requesting guest shutdown…")
        try? controller.requestShutdown()
        if let console {
            try await Task.sleep(for: .seconds(5))
            log("after stop request: \(try await console.screenshot())")
            // requestStop() only opens the guest's "Shut down now?" dialog; Return confirms it.
            _ = try await console.execute("key return")
        }
        let deadline = Date().addingTimeInterval(90)
        while controller.state != .stopped, Date() < deadline {
            try await Task.sleep(for: .seconds(1))
        }
        if controller.state != .stopped {
            log("guest did not stop in 90s, forcing")
            try await controller.forceStop()
        }
        log("stopped")
    }

    static func status() throws {
        let bundle = self.bundle
        print("bundle: \(bundle.url.path)")
        if let spec = try? bundle.loadSpec() {
            print("stage: \(spec.stage.rawValue), build: \(spec.restoreImageBuild ?? "-"), mac: \(spec.macAddress), overlays: \(spec.overlayCount)")
        } else {
            print("no spec yet")
        }
        for url in [bundle.baseDiskURL, bundle.savedStateURL, bundle.restoreImageURL] {
            print("\(url.lastPathComponent): \(diskUsage(url))")
        }
    }

    // MARK: Host-only checks (no guest needed)

    /// P4 and P5 at the API level: build an ASIF base + overlay stack and a vmnet attachment.
    static func selftest() throws {
        let scratch = VMBundle(url: FileManager.default.temporaryDirectory.appendingPathComponent("cc-selftest-\(UUID().uuidString).vm"))
        try scratch.create()
        defer { try? FileManager.default.removeItem(at: scratch.url) }
        var spec = VMSpec(macAddress: VZMACAddress.randomLocallyAdministered().string)
        spec.diskBytes = 4 << 30
        let disks = DiskStack(bundle: scratch)

        var started = Date()
        try disks.createBlankBase(bytes: spec.diskBytes)
        log("P4 blank ASIF base: \(elapsed(since: started)), \(diskUsage(scratch.baseDiskURL))")
        _ = try disks.makeAttachment(spec: spec)
        log("P4 attachment without overlays: ok")

        started = Date()
        try disks.pushOverlay(spec: &spec)
        log("P4 pushOverlay → overlay-1: \(elapsed(since: started)), exists: \(FileManager.default.fileExists(atPath: scratch.overlayURL(1).path)), \(diskUsage(scratch.overlayURL(1)))")
        _ = try disks.makeAttachment(spec: spec)
        log("P4 attachment base+overlay-1: ok")
        try disks.pushOverlay(spec: &spec)
        _ = try disks.makeAttachment(spec: spec)
        log("P4 attachment base+2 overlays: ok")
        try disks.discardOverlays(spec: &spec, keeping: 0)
        _ = try disks.makeAttachment(spec: spec)
        log("P4 reset (keeping: 0) → overlayCount \(spec.overlayCount), overlay-2 gone: \(!FileManager.default.fileExists(atPath: scratch.overlayURL(2).path))")

        started = Date()
        let device = try NetworkProvider().makeDevice(macAddress: spec.macAddress)
        log("P5 vmnet shared-mode device: \(type(of: device.attachment!)) in \(elapsed(since: started))")
    }

    // MARK: Helpers

    static let clockStart = Date()

    static func log(_ message: String) {
        print(String(format: "[%7.1fs] ", Date().timeIntervalSince(clockStart)) + message)
        fflush(stdout)
    }

    static func elapsed(since date: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(date))
    }

    /// Allocated (not logical) size, since ASIF disks and save files are sparse.
    static func diskUsage(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return "missing" }
        let allocated = Double(values.totalFileAllocatedSize ?? 0) / 1e9
        let logical = Double(values.fileSize ?? 0) / 1e9
        return String(format: "%.1f GB allocated / %.1f GB logical", allocated, logical)
    }
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

#endif

#if os(macOS)
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
#endif
