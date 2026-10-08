#if os(macOS)
import CoreGraphics
import Foundation

/// Walks a fresh macOS 26 guest through Setup Assistant from the host, the way a person would, and leaves it at the
/// desktop with SSH on, so the agent installs exactly as on macOS 27 (where the account is created on first boot).
///
/// Each round reads the screen (on-device text recognition), recognizes the page by its title and acts on it by
/// the buttons' labels. Choices are the least sharing ones: no Apple Account, no location, no analytics, no
/// Screen Time, no FileVault (it would stop automatic login), updates downloaded but not installed.
/// Measured on macOS 26.6.2 (25G83).
@MainActor
public struct SetupAssistant {
    public let display: HostDisplay
    public let fullName: String
    public let username: String
    public let password: () throws -> String
    public let log: (String) -> Void
    /// Every screen it reads, with the page it recognized: for looking into a setup that went wrong.
    public var trace: ((String, CGImage) -> Void)?

    public init(display: HostDisplay, fullName: String, username: String, password: @escaping () throws -> String,
                log: @escaping (String) -> Void = { _ in }, trace: ((String, CGImage) -> Void)? = nil) {
        self.display = display
        self.fullName = fullName
        self.username = username
        self.password = password
        self.log = log
        self.trace = trace
    }

    /// Where the page's main button sits when its label isn't read (the hello screen's is localized).
    private var helloButton: CGPoint { CGPoint(x: display.guestSize.width / 2, y: display.guestSize.height * 0.852) }

    /// Runs until the desktop shows, then turns on SSH and automatic login from Terminal.
    public func run(timeout: TimeInterval = 900) async throws {
        let started = Date()
        var lastPage = ""
        var repeats = 0
        var unreadable = 0
        while Date().timeIntervalSince(started) < timeout {
            // The screen can't be read for a moment while the guest switches displays (after the account is
            // created it logs in): wait for it rather than give up.
            guard let image = display.capture() else {
                unreadable += 1
                guard unreadable < 90 else { throw HostControlError.noFramebuffer }
                try await Task.sleep(for: .seconds(2))
                continue
            }
            unreadable = 0
            let screen = try ScreenText.recognize(image, guestSize: display.guestSize)
            let page = Self.page(screen)
            trace?(page, image)
            // Pages slide in: text shows before the controls take clicks and typing. Act on a page only when the
            // next read still shows it.
            if page != lastPage {
                lastPage = page
                repeats = -1
                try await Task.sleep(for: .seconds(1))
                continue
            }
            repeats += 1
            // A page that doesn't change after several tries: let it settle, then try its fallback.
            guard repeats < 12 else { throw HostControlError.gaveUp("Setup Assistant stayed on “\(page)”.") }
            if page == "desktop" {
                log("setup assistant: done")
                try await enableRemoteLogin()
                return
            }
            if repeats == 0 { log("setup assistant: \(page)") }
            try await act(on: page, screen, attempt: repeats)
            try await Task.sleep(for: .seconds(page == "creating account" || page == "working" ? 3 : 2))
        }
        throw HostControlError.gaveUp("Setup Assistant did not finish in \(Int(timeout / 60)) minutes.")
    }

    /// The page, recognized by text that only it shows. Dialogs are checked before the page under them.
    nonisolated static func page(_ screen: ScreenText) -> String {
        let checks: [(String, [String])] = [
            // Dialog text wraps, so each needle is a fragment that stays on one recognized line.
            ("skip apple account?", ["want to skip", "Don't Skip", "Don’t Skip"]),
            ("agree dialog", ["read and agree"]),
            ("location dialog", ["Don't Use", "Don’t Use"]),
            ("filevault dialog", ["Securely Encrypted"]),
            ("creating account", ["Creating account"]),
            ("missing information", ["haven't provided all", "haven’t provided all"]),
            ("language", ["Language"]),
            ("country", ["Select Your Country or Region"]),
            ("transfer", ["Transfer Your Data"]),
            ("languages", ["Written and Spoken Languages"]),
            ("accessibility", ["Accessibility features adapt"]),
            ("data & privacy", ["Data & Privacy"]),
            ("account", ["Create a Mac Account"]),
            ("apple account", ["Sign In to Your Apple Account", "Sign in with your Apple Account"]),
            ("terms", ["Terms and Conditions"]),
            ("age", ["Age Range"]),
            ("location", ["Enable Location Services"]),
            ("time zone", ["Select Your Time Zone"]),
            ("analytics", ["Share Mac Analytics"]),
            ("screen time", ["Screen Time"]),
            ("siri", ["Siri"]),
            ("filevault", ["Ready for FileVault", "FileVault"]),
            ("touch id", ["Touch ID"]),
            ("look", ["Choose Your Look"]),
            ("updates", ["Update Mac Automatically"]),
            ("welcome", ["Get Started"]),
        ]
        for (name, needles) in checks where needles.contains(where: { screen.contains($0) }) {
            // "Language" is also part of other pages' text; only the first page has it as its title alone.
            if name == "language", !screen.items.contains(where: { $0.text == "Language" }) { continue }
            if name == "screen time", !screen.contains("Weekly Reports") && !screen.contains("Set Up Later") { continue }
            if name == "siri", !screen.contains("Enable Ask Siri") && !screen.contains("Siri Suggestions") { continue }
            return name
        }
        // The desktop: Finder's menu bar, and no Setup Assistant window.
        if screen.contains("Finder"), screen.contains("Go"), screen.contains("Window") { return "desktop" }
        // The hello screen greets in a rotating language: no fixed text to read.
        return screen.items.count <= 3 ? "hello" : "working"
    }

    private func act(on page: String, _ screen: ScreenText, attempt: Int) async throws {
        func click(_ label: String) -> Bool {
            guard let item = screen.first(label) else { return false }
            display.click(item.center)
            return true
        }
        func next() async throws {
            if !click("Continue") { try await display.key("return") }
        }
        switch page {
        case "hello":
            display.click(helloButton)
        case "working", "creating account":
            break
        case "language":
            try await display.key("return")
        case "country":
            // The list's selection must be clicked once before Continue enables.
            _ = click("United States")
            try await Task.sleep(for: .seconds(1))
            try await next()
        case "transfer":
            _ = click("Set up as new")
            try await Task.sleep(for: .seconds(1))
            try await next()
        case "accessibility", "siri":
            if !click("Not Now") && !click("Set Up Later") { try await next() }
        case "account":
            try await fillAccount(screen)
        case "missing information":
            // Something didn't take on the account page: go back and fill it in again.
            if !click("Go Back") { try await display.key("return") }
        case "apple account":
            // Other Sign-In Options › Sign in Later in Settings, then confirm the skip.
            if !click("Sign in Later") && !click("Set Up Later") {
                _ = click("Other Sign-In Options")
            }
        case "skip apple account?":
            if !click("Skip") { try await display.key("return") }
        case "terms":
            _ = click("Agree")
        case "agree dialog":
            // Two "Agree" buttons are on screen; the dialog's is the higher one.
            if let agree = screen.items.filter({ $0.text == "Agree" }).min(by: { $0.rect.minY < $1.rect.minY }) {
                display.click(agree.center)
            }
        case "age":
            _ = click("Adult")
        case "location dialog":
            if !click("Don't Use") && !click("Don’t Use") { try await display.key("return") }
        case "analytics":
            // Turn off sharing: the first box is checked by default. Clicking twice would turn it back on, so only
            // on the first look at this page.
            if attempt == 0, let label = screen.first("Share Mac Analytics") {
                display.click(CGPoint(x: label.rect.minX - 11, y: label.rect.midY))
                try await Task.sleep(for: .seconds(1))
            }
            try await next()
        case "screen time":
            if !click("Set Up Later") { try await next() }
        case "filevault":
            if !click("Not Now") { try await next() }
        case "filevault dialog":
            if !click("Continue") { try await display.key("return") }
        case "updates":
            if !click("Only Download Automatically") { try await next() }
        case "welcome":
            _ = click("Get Started")
        default:
            try await next()
        }
    }

    /// Full name, account name, password twice; and no password reset through an Apple Account. Presses Continue
    /// only once the screen shows the fields filled (their placeholders gone); otherwise the next round fills again.
    private func fillAccount(_ screen: ScreenText) async throws {
        let placeholders = ["Full Name", "Account Name", "Password", "Verify Password"]
        let empty = placeholders.compactMap { label in screen.items.first { $0.text == label } }
        guard !empty.isEmpty else {
            // Filled in: the Apple Account reset box off, then Continue.
            if let continueButton = screen.first("Continue") { display.click(continueButton.center) }
            log("setup assistant: account \(username) created")
            return
        }
        let secret = try password()
        let both = empty.contains { $0.text == "Password" }
        for field in empty {
            // With both password fields empty, the second is reached with Tab from the first: once the password
            // is typed, a popover can cover the "Verify Password" field's place on screen.
            if both, field.text == "Verify Password" { continue }
            display.click(field.center)
            try await Task.sleep(for: .milliseconds(400))
            switch field.text {
            case "Full Name":
                try await display.type(fullName)
            case "Account Name":
                // Filled in from the full name; replace it.
                try await display.key("cmd+a")
                try await display.type(username)
            case "Password":
                try await display.type(secret)
                try await display.key("tab")
                try await Task.sleep(for: .milliseconds(300))
                try await display.type(secret)
            default:
                try await display.type(secret)
            }
        }
        // Only on the pass that filled the full name, so a second pass can't turn the box back on.
        if empty.contains(where: { $0.text == "Full Name" }), let reset = screen.first("Allow computer account password") {
            display.click(CGPoint(x: reset.rect.minX - 11, y: reset.rect.midY))
        }
    }

    /// Remote Login and automatic login, from Terminal: `systemsetup` needs Full Disk Access on macOS 26, so sshd
    /// is started with launchctl. The password goes only to sudo's prompts, never on a command line.
    private func enableRemoteLogin() async throws {
        let secret = try password()
        try await display.key("cmd+space")
        try await Task.sleep(for: .seconds(1.5))
        try await display.type("Terminal")
        try await Task.sleep(for: .seconds(1))
        try await display.key("return")
        try await Task.sleep(for: .seconds(4))
        try await display.type("sudo launchctl enable system/com.openssh.sshd && sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist; sudo sysadminctl -autologin set -userName \(username) -password -")
        try await display.key("return")
        try await Task.sleep(for: .seconds(2))
        try await display.type(secret)      // sudo
        try await display.key("return")
        try await Task.sleep(for: .seconds(4))
        try await display.type(secret)      // sysadminctl's own prompt
        try await display.key("return")
        try await Task.sleep(for: .seconds(3))
        try await display.type("exit")
        try await display.key("return")
        try await Task.sleep(for: .seconds(1))
        try await display.key("cmd+q")
        log("setup assistant: remote login and automatic login on")
    }

    private func read() throws -> ScreenText {
        guard let image = display.capture() else { throw HostControlError.noFramebuffer }
        return try ScreenText.recognize(image, guestSize: display.guestSize)
    }
}
#endif
