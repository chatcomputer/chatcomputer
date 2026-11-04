#if os(macOS)
import AppKit
import ApplicationServices
import BridgeProtocol
import CoreGraphics
import Security

/// The menu and vsock use the same coordinator. A request is launched, never
/// awaited by the command reader; a system modal must not block health replies.
@MainActor
public final class PermissionRequests {
    private var requested: Set<PermissionKind> = []
    public private(set) var active: PermissionKind?
    public private(set) var events: [PermissionEvent] = []

    public init() {}

    @discardableResult
    public func begin(_ kind: PermissionKind, granted: Bool,
                      request: @escaping @Sendable () async -> Bool) -> Bool {
        if granted { record(kind, "already-granted"); return false }
        if let active, active != kind {
            record(kind, "request-deferred-other-permission")
            return false
        }
        guard active == nil, !requested.contains(kind) else {
            record(kind, "request-coalesced")
            return false
        }
        requested.insert(kind)
        active = kind
        record(kind, "request-started")
        Task { [self] in
            let granted = await request()
            active = nil
            record(kind, granted ? "request-returned-granted" : "request-returned-awaiting-settings")
        }
        return true
    }

    /// A human explicitly repairing an old signing identity may reset it once.
    /// Never reset a live system prompt or use reset as an automatic retry.
    public func repair(_ kind: PermissionKind, reset: @Sendable () async -> Bool) async -> Bool {
        guard active == nil else { record(kind, "repair-refused-request-pending"); return false }
        active = kind
        record(kind, "explicit-repair-started")
        let succeeded = await reset()
        if succeeded { requested.remove(kind) }
        record(kind, succeeded ? "explicit-repair-finished" : "explicit-repair-failed")
        active = nil
        return succeeded
    }

    public func record(_ kind: PermissionKind, _ stage: String) {
        events.append(PermissionEvent(kind: kind, stage: stage))
        if events.count > 64 { events.removeFirst(events.count - 64) }
    }
}

@MainActor
public enum PermissionSetup {
    public static let requests = PermissionRequests()
    private static var probe: NSWindow?

    @discardableResult
    public static func prepare(_ kind: PermissionKind) -> Bool {
        // Bring our own pending consent to the front, without opening Settings.
        NSApp.activate()
        let granted = kind == .accessibility ? AXIsProcessTrusted() : CGPreflightScreenCaptureAccess()
        if !granted, let active = requests.active, active != kind {
            requests.record(kind, "request-deferred-other-permission")
            return false
        }
        requests.begin(kind, granted: granted) {
            // CoreGraphics/AX requests may wait for a system prompt. Do not occupy
            // the main actor or the vsock command reader while it is unanswered.
            await Task.detached {
                switch kind {
                case .accessibility:
                    return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                case .screenRecording:
                    return CGRequestScreenCaptureAccess()
                }
            }.value
        }
        return true
    }

    public static func openSettings(_ kind: PermissionKind) {
        guard requests.active == nil else {
            requests.record(kind, "settings-deferred-request-pending")
            NSApp.activate()
            return
        }
        let pane = kind == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            requests.record(kind, "settings-opened")
            NSWorkspace.shared.open(url)
        }
    }

    public static func repair(_ kind: PermissionKind) async -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.chatcomputer.agent"
        return await requests.repair(kind) {
            await Task.detached {
                let reset = Process()
                reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                reset.arguments = ["reset", kind.tccService, bundleID]
                do { try reset.run() } catch { return false }
                reset.waitUntilExit()
                guard reset.terminationStatus == 0 else { return false }
                try? await Task.sleep(for: .seconds(4))
                return true
            }.value
        }
    }

    static var captureProbeVisible: Bool { probe != nil }

    public static func showCaptureProbe(_ marker: String?) {
        probe?.close()
        probe = nil
        guard let marker else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Chat Computer capture check"
        // Verification also runs after restoring a session with another app in
        // front. A background menu-bar app cannot rely on activation to raise a
        // normal window above that app's document. The probe needs no focus.
        window.level = .floating
        window.hidesOnDeactivate = false
        let label = NSTextField(labelWithString: marker)
        label.font = .monospacedSystemFont(ofSize: 30, weight: .bold)
        label.alignment = .center
        label.frame = NSRect(x: 10, y: 50, width: 540, height: 50)
        window.contentView?.addSubview(label)
        window.center()
        window.orderFrontRegardless()
        probe = window
    }

    public static func diagnostics() -> PermissionDiagnostics {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        }
        let signing = info as? [String: Any]
        let build = (try? String(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist", encoding: .utf8))
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["ProductBuildVersion"] as? String
        return PermissionDiagnostics(processID: ProcessInfo.processInfo.processIdentifier,
                                     bundleID: Bundle.main.bundleIdentifier ?? "unbundled",
                                     teamID: signing?[kSecCodeInfoTeamIdentifier as String] as? String,
                                     osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                     osBuild: build ?? "unknown", events: requests.events)
    }
}
#endif
