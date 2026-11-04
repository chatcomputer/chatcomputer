#if os(macOS)
import Foundation

/// The macOS 26 bootstrap must observe real terminal prompts. Blindly typing
/// two passwords after fixed sleeps can feed a secret to the shell instead.
@MainActor
struct TerminalBootstrap {
    var read: () throws -> ScreenText
    var key: (String) async throws -> Void
    var type: (String) async throws -> Void
    var password: () throws -> String
    var pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var verificationID = String(Int.random(in: 100_000...999_999))
    var log: (String) -> Void = { _ in }

    static let auth = "CC_BOOTSTRAP_AUTH"
    static let accountAuth = "CC_BOOTSTRAP_ACCOUNT_AUTH"
    static let ready = "CC_BOOTSTRAP_READY"
    static let failed = "CC_BOOTSTRAP_FAILED"
    static let shell = "CC_BOOTSTRAP_SHELL"

    func run(username: String) async throws {
        guard !username.isEmpty, username.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }) else { throw HostControlError.gaveUp("The guest account name is invalid.") }
        // A retry often resumes Terminal itself. Opening Spotlight over it
        // leaves the old Terminal menu visible, so that menu cannot prove
        // Spotlight has finished handing keyboard focus back to Terminal.
        var terminalReady = Self.isTerminal(try read())
        if !terminalReady {
            try await key("cmd+space")
            try await pause(.seconds(1.5))
            try await type("Terminal")
            try await pause(.seconds(1))
            try await key("return")
            try await pause(.seconds(1))
            for _ in 0..<30 {
                try Task.checkCancellation()
                if Self.isTerminal(try read()) { terminalReady = true; break }
                try await pause(.seconds(1))
            }
        }
        guard terminalReady else {
            throw HostControlError.gaveUp("Terminal did not open in the virtual Mac. Keep Chat Computer in front and retry setup.")
        }
        func matchesMarker(_ prefix: String, in screen: ScreenText) -> Bool {
            func normalize(_ text: String) -> String { text.filter { $0.isLetter || $0.isNumber }.uppercased() }
            let marker = normalize(prefix + "_" + verificationID)
            return screen.items.contains { normalize($0.text) == marker }
        }
        // Interrupt delivery is asynchronous. Prove the shell has resumed
        // before sending sudo, rather than feeding a command to an old prompt.
        try await key("ctrl+c")
        try await pause(.seconds(1))
        try await key("cmd+k")
        try await key("ctrl+u")
        try await type("printf '" + Self.marker(Self.shell + "_" + verificationID) + "'")
        try await key("return")
        var shellReady = false
        for _ in 0..<15 {
            try Task.checkCancellation()
            let screen = try read()
            if Self.isTerminal(screen), matchesMarker(Self.shell, in: screen) { shellReady = true; break }
            try await pause(.seconds(1))
        }
        guard shellReady else {
            throw HostControlError.gaveUp("Terminal did not return to its command prompt. Setup stopped without entering a password. Cancel its current command and retry setup.")
        }
        try await type(Self.command(username: username, verificationID: verificationID))
        try await key("return")
        var sudoAnswered = false
        var accountAnswered = false
        var accountCommandStarted = false
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(90))
        for _ in 0..<90 {
            try Task.checkCancellation()
            if clock.now >= deadline { break }
            let screen = try read()
            func hasMarker(_ prefix: String) -> Bool { matchesMarker(prefix, in: screen) }
            let terminal = Self.isTerminal(screen)
            let authPrefix = Self.auth.filter { $0.isLetter || $0.isNumber }.uppercased()
            let seesAuthPrefix = screen.items.contains {
                $0.text.filter { $0.isLetter || $0.isNumber }.uppercased().hasPrefix(authPrefix)
            }
            log("observed terminal=\(terminal) auth=\(hasMarker(Self.auth)) authPrefix=\(seesAuthPrefix) account=\(hasMarker(Self.accountAuth)) ready=\(hasMarker(Self.ready)) failed=\(hasMarker(Self.failed)) items=\(screen.items.count)")
            guard terminal else { try await pause(.seconds(1)); continue }
            if screen.contains("Sorry, try again") || screen.contains("incorrect password") {
                throw HostControlError.gaveUp("The virtual Mac did not accept its saved password. Setup stopped without typing it again.")
            }
            if hasMarker(Self.failed) {
                throw HostControlError.gaveUp("Remote Login or automatic login did not enable in the virtual Mac. Keep its Terminal window open and retry setup.")
            }
            if hasMarker(Self.ready) {
                try await type("exit")
                try await key("return")
                try await pause(.seconds(1))
                try await key("cmd+q")
                return
            }
            if hasMarker(Self.accountAuth) { accountCommandStarted = true }
            let prompts = screen.items.map { $0.text.trimmingCharacters(in: .whitespaces).lowercased() }
            if accountCommandStarted, !accountAnswered, prompts.contains(where: { $0.hasPrefix("enter password") }) {
                log("answering-account-prompt")
                try await type(password())
                try await key("return")
                accountAnswered = true
            } else if !sudoAnswered, hasMarker(Self.auth) {
                log("answering-sudo-prompt")
                try await type(password())
                try await key("return")
                sudoAnswered = true
            }
            try await pause(.seconds(1))
        }
        throw HostControlError.gaveUp("The virtual Mac did not confirm Remote Login and automatic login. Setup stopped; no agent was installed.")
    }

    nonisolated static func isTerminal(_ screen: ScreenText) -> Bool {
        // Vision can merge adjacent menu titles into one "Terminal Shell"
        // block. Match complete words in the menu bar, never document text.
        let words = screen.items.filter { $0.rect.minY < 32 }.flatMap {
            $0.text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        }
        return ["Terminal", "Shell"].allSatisfy(words.contains)
    }

    static func command(username: String, verificationID: String = "000000") -> String {
        // End the prompt with a newline and a space. The space preserves that
        // newline through shell substitution, leaving Terminal's secure-input
        // key icon on a separate line where it cannot hide the prompt from OCR.
        let prompt = "$(printf '" + marker(auth + "_" + verificationID) + " ')"
        return "sudo -k -p \"" + prompt + "\" /bin/sh -c '"
            + script(username: username, verificationID: verificationID).replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func marker(_ value: String) -> String {
        value.utf8.map { "\\" + String($0, radix: 8) }.joined() + "\\012"
    }

    static func script(username: String, verificationID: String = "000000") -> String {
        // Octal markers are not visible literally in the echoed command, so OCR
        // cannot mistake the command itself for a successful result.
        return """
            if launchctl enable system/com.openssh.sshd && \
            { launchctl print system/com.openssh.sshd >/dev/null 2>&1 || launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist; } && \
            { launchctl kickstart -k system/com.openssh.sshd >/dev/null 2>&1 || true; } && \
            printf '\(marker(accountAuth + "_" + verificationID))' && \
            sysadminctl -autologin set -userName '\(username)' -password - && \
            /usr/bin/nc -z -G 2 127.0.0.1 22 && \
            sysadminctl -autologin status 2>&1 | grep -F 'Automatic login user: \(username)' >/dev/null; \
            then printf '\(marker(ready + "_" + verificationID))'; else printf '\(marker(failed + "_" + verificationID))'; fi
            """
    }
}
#endif
