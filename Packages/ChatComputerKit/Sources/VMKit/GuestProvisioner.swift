#if os(macOS)
import Foundation
import Security
import Virtualization
import ChatCore

/// Onboarding steps 4–5: create the guest account on first boot, then install and pair the guest agent.
public struct GuestProvisioner: Sendable {
    public let bundle: VMBundle
    public let secrets: any SecretStore

    public init(bundle: VMBundle, secrets: any SecretStore) {
        self.bundle = bundle
        self.secrets = secrets
    }

    /// Options for the very first boot (macOS 27 `VZMacGuestProvisioningOptions`).
    /// A random per-VM password, kept only in the host's secret store; there is no default password.
    /// `password` overrides it for development (a short password you can type into the guest).
    /// Remote login is enabled solely so `installAgent` can run; bootstrap turns it off again.
    public func firstBootOptions(spec: VMSpec, password override: String? = nil) throws -> VZMacGuestProvisioningOptions {
        let password = override ?? Self.randomSecret()
        try secrets.write(password, for: SecretAccount.guestPassword(vmID: spec.id))

        let options = VZMacGuestProvisioningOptions()
        options.fullName = spec.name
        options.username = spec.guestUsername
        options.password = password
        options.logsInAutomatically = true   // the driver needs a logged-in Aqua session
        options.enablesRemoteLogin = true
        return options
    }

    /// Copies the agent and its pairing file into the bootstrap share and installs them over SSH.
    ///
    /// `agentApp` is the signed ChatComputerAgent.app embedded in the host app's resources.
    /// `subnet` is the VM network's current subnet; stale leases from earlier boots lie outside it.
    public func installAgent(spec: VMSpec, agentApp: URL, subnet: IPv4Subnet?, waitMinutes: Int = 10) async throws {
        let password = try secrets.read(SecretAccount.guestPassword(vmID: spec.id))
        guard let password else { throw VMError.bootstrapFailed("guest password missing from secrets.json") }

        let pairingToken = Self.randomSecret()
        try stageBootstrapFiles(spec: spec, agentApp: agentApp, pairingToken: pairingToken)

        let address = try await guestAddress(macAddress: spec.macAddress, subnet: subnet, attempts: waitMinutes * 30)
        try await runSSH(user: spec.guestUsername, host: address, password: password, script: Self.bootstrapScript)
        // Stored only once the guest has it: a failed attempt must not orphan the agent an earlier
        // attempt installed (it would be rejected forever, and SSH is already off by then).
        try secrets.write(pairingToken, for: SecretAccount.pairingToken(vmID: spec.id))

        // The bootstrap share holds the pairing token; clear it once the agent has copied it.
        try? FileManager.default.removeItem(at: bundle.bootstrapDirectory.appendingPathComponent("pairing.json"))
    }

    private func stageBootstrapFiles(spec: VMSpec, agentApp: URL, pairingToken: String) throws {
        let fm = FileManager.default
        let directory = bundle.bootstrapDirectory
        let stagedApp = directory.appendingPathComponent("ChatComputerAgent.app")
        try? fm.removeItem(at: stagedApp)
        try fm.copyItem(at: agentApp, to: stagedApp)

        let pairing = ["vmID": spec.id.uuidString, "pairingToken": pairingToken]
        try JSONSerialization.data(withJSONObject: pairing).write(to: directory.appendingPathComponent("pairing.json"))

        let launchAgent: [String: Any] = [
            "Label": "app.chatcomputer.agent",
            "Program": "/Users/\(spec.guestUsername)/Applications/ChatComputerAgent.app/Contents/MacOS/ChatComputerAgent",
            "RunAtLoad": true,
            "KeepAlive": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        try PropertyListSerialization.data(fromPropertyList: launchAgent, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("app.chatcomputer.agent.plist"))
    }

    /// Runs in the guest as the provisioned user. The last step switches SSH off again.
    /// Verified on macOS 27.0.1: the virtio-fs automount is visible to the SSH session.
    static let bootstrapScript = #"""
        set -euo pipefail
        SRC="/Volumes/My Shared Files/bootstrap"
        SUPPORT="$HOME/Library/Application Support/ChatComputerAgent"
        mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$SUPPORT"
        rm -rf "$HOME/Applications/ChatComputerAgent.app"
        ditto "$SRC/ChatComputerAgent.app" "$HOME/Applications/ChatComputerAgent.app"
        install -m 600 "$SRC/pairing.json" "$SUPPORT/pairing.json"
        cp "$SRC/app.chatcomputer.agent.plist" "$HOME/Library/LaunchAgents/"
        # An SSH session is not in the Aqua session, so only root may bootstrap into gui/<uid>
        # (as the user it fails with 125 "Domain does not support specified action", macOS 27).
        printf "%s\n" "$CC_GUEST_PASSWORD" | sudo -S -p "" launchctl bootout "gui/$(id -u)/app.chatcomputer.agent" 2>/dev/null || true
        printf "%s\n" "$CC_GUEST_PASSWORD" | sudo -S -p "" launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/app.chatcomputer.agent.plist"
        # A machine that only the agent works on: never sleep, blank or lock the screen. A locked guest stops
        # the agent (and the host's own permission step) until someone types the password.
        printf "%s\n" "$CC_GUEST_PASSWORD" | sudo -S -p "" pmset -a sleep 0 displaysleep 0 disksleep 0
        sysadminctl -screenLock off -password "$CC_GUEST_PASSWORD" 2>/dev/null || true
        defaults -currentHost write com.apple.screensaver idleTime -int 0
        # Detached and delayed so this SSH session exits cleanly before sshd goes away.
        nohup bash -c 'sleep 3; printf "%s\n" "$CC_GUEST_PASSWORD" | sudo -S -p "" systemsetup -f -setremotelogin off' >/dev/null 2>&1 &
        """#

    /// Finds the guest's DHCP lease by MAC address (vmnet shared mode serves leases through bootpd)
    /// and waits until its SSH port answers. Leases outlive boots, so an address can be known
    /// long before the guest is up; it is re-read on every attempt in case it changes.
    /// The first boot after provisioning can take several minutes before SSH answers (it was 30 s in one fresh
    /// install and never in another), so the wait is long; the caller restarts the guest if it runs out.
    private func guestAddress(macAddress: String, subnet: IPv4Subnet?, attempts: Int) async throws -> String {
        for _ in 0..<attempts {
            if let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8),
               let ip = Self.leaseAddress(in: leases, macAddress: macAddress, subnet: subnet),
               await Self.portIsOpen(host: ip, port: 22) {
                return ip
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw VMError.guestAddressUnknown
    }

    private static func portIsOpen(host: String, port: Int) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-z", "-G", "2", host, "\(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.finish() }
        }
        guard (try? process.run()) != nil else { return false }
        for await _ in exited {}
        return process.terminationStatus == 0
    }

    /// The lease file keeps entries from earlier boots, possibly on other subnets, so only leases
    /// inside the current subnet count, and the one expiring last wins. bootpd writes MAC octets
    /// without leading zeros.
    static func leaseAddress(in leases: String, macAddress: String, subnet: IPv4Subnet?) -> String? {
        let normalized = macAddress.lowercased().split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":")
        var best: (ip: String, expiry: UInt64)?
        for entry in leases.components(separatedBy: "}") {
            var fields: [String: String] = [:]
            for line in entry.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                fields[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
            }
            guard fields["hw_address"] == "1,\(normalized)", let ip = fields["ip_address"] else { continue }
            if let subnet, !subnet.contains(ip) { continue }
            let expiry = fields["lease"].flatMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } ?? 0
            if best == nil || expiry > best!.expiry { best = (ip, expiry) }
        }
        return best?.ip
    }

    /// SSH with a pinned per-VM known_hosts, password via SSH_ASKPASS, and no agent/port forwarding.
    private func runSSH(user: String, host: String, password: String, script: String) async throws {
        let askpass = FileManager.default.temporaryDirectory.appendingPathComponent("cc-askpass-\(UUID().uuidString)")
        try "#!/bin/sh\nprintf '%s\\n' \"$CC_GUEST_PASSWORD\"\n".write(to: askpass, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        defer { try? FileManager.default.removeItem(at: askpass) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(bundle.knownHostsURL.path)",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ConnectTimeout=10",
            "\(user)@\(host)",
            "bash -s",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpass.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["CC_GUEST_PASSWORD"] = password
        process.environment = environment

        // The script and the password for its sudo step travel over the encrypted stdin, never argv.
        // The password is base64, so single quotes need no escaping.
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        let exited = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.finish() }
        }
        try process.run()
        input.fileHandleForWriting.write(Data("export CC_GUEST_PASSWORD='\(password)'\n\(script)\n".utf8))
        try input.fileHandleForWriting.close()
        for await _ in exited {}

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw VMError.bootstrapFailed(message.isEmpty ? "ssh exit \(process.terminationStatus)" : message)
        }
    }

    static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
#endif
