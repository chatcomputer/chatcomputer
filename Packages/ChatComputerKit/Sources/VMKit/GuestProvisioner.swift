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
    /// A random per-VM password goes to the Keychain only; there is no default password.
    /// Remote login is enabled solely so `installAgent` can run; bootstrap turns it off again.
    public func firstBootOptions(spec: VMSpec) throws -> VZMacGuestProvisioningOptions {
        let password = Self.randomSecret()
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
    public func installAgent(spec: VMSpec, agentApp: URL) async throws {
        let password = try secrets.read(SecretAccount.guestPassword(vmID: spec.id))
        guard let password else { throw VMError.bootstrapFailed("guest password missing from Keychain") }

        let pairingToken = Self.randomSecret()
        try secrets.write(pairingToken, for: SecretAccount.pairingToken(vmID: spec.id))
        try stageBootstrapFiles(spec: spec, agentApp: agentApp, pairingToken: pairingToken)

        let address = try await guestAddress(macAddress: spec.macAddress)
        try await runSSH(user: spec.guestUsername, host: address, password: password, script: Self.bootstrapScript)

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
    /// TODO(P1): confirm the automount is visible to the SSH session and that the sudo step works
    /// without Full Disk Access on macOS 27; otherwise move it to a first-run step in the agent.
    static let bootstrapScript = #"""
        set -euo pipefail
        SRC="/Volumes/My Shared Files/bootstrap"
        SUPPORT="$HOME/Library/Application Support/ChatComputerAgent"
        mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$SUPPORT"
        rm -rf "$HOME/Applications/ChatComputerAgent.app"
        ditto "$SRC/ChatComputerAgent.app" "$HOME/Applications/ChatComputerAgent.app"
        install -m 600 "$SRC/pairing.json" "$SUPPORT/pairing.json"
        cp "$SRC/app.chatcomputer.agent.plist" "$HOME/Library/LaunchAgents/"
        launchctl bootout "gui/$(id -u)/app.chatcomputer.agent" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/app.chatcomputer.agent.plist"
        # Detached and delayed so this SSH session exits cleanly before sshd goes away.
        nohup bash -c 'sleep 3; printf "%s\n" "$CC_GUEST_PASSWORD" | sudo -S -p "" systemsetup -f -setremotelogin off' >/dev/null 2>&1 &
        """#

    /// Finds the guest's DHCP lease by MAC address (vmnet shared mode serves leases through bootpd).
    /// TODO(P5): replace with a vmnet API if the custom network exposes leases directly.
    private func guestAddress(macAddress: String) async throws -> String {
        let normalized = macAddress.lowercased().split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":")
        for _ in 0..<60 {
            if let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) {
                var ip: String?
                for line in leases.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if line.hasPrefix("ip_address=") { ip = String(line.dropFirst("ip_address=".count)) }
                    if line.hasPrefix("hw_address=1,"), line.dropFirst("hw_address=1,".count) == normalized, let ip {
                        return ip
                    }
                }
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw VMError.guestAddressUnknown
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
