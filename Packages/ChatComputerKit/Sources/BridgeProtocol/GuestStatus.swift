import Foundation

/// Whether the guest can take work, and if not, what the user should know. Built from the bridge state and
/// the agent's health report (the readiness probe, proposal §06).
public enum GuestReadiness: Equatable, Sendable {
    case ready
    case agentNotConnected
    case agentNotAnswering
    case noDesktopSession
    case screenLocked
    case missingPermissions(accessibility: Bool, screenRecording: Bool)

    public init(connected: Bool, report: HealthReport?) {
        guard connected else { self = .agentNotConnected; return }
        guard let report else { self = .agentNotAnswering; return }
        if report.isDesktopReady { self = .ready }
        else if !report.hasAquaSession { self = .noDesktopSession }
        else if report.screenLocked { self = .screenLocked }
        else { self = .missingPermissions(accessibility: !report.accessibilityGranted, screenRecording: !report.screenRecordingGranted) }
    }

    public var isReady: Bool { self == .ready }

    /// One line for the user; nil when ready.
    public var problem: String? {
        switch self {
        case .ready: nil
        case .agentNotConnected: "the agent in the virtual Mac is not connected (it may be starting or restarting)"
        case .agentNotAnswering: "the agent in the virtual Mac is connected but not answering"
        case .noDesktopSession: "nobody is logged in to the virtual Mac's desktop"
        case .screenLocked: "the virtual Mac's screen is locked"
        case .missingPermissions(let accessibility, let screenRecording):
            "the agent in the virtual Mac lacks " + [accessibility ? "Accessibility" : nil, screenRecording ? "Screen Recording" : nil]
                .compactMap { $0 }.joined(separator: " and ") + " permission"
        }
    }
}

/// The guest agent's version as it reports it: marketing version and build, so every build is told apart.
public enum AgentVersion {
    public static func string(short: String, build: String) -> String { "\(short) (\(build))" }

    /// Reads the version of an agent bundle on disk, in the same form.
    public static func of(bundle url: URL) -> String? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let short = info["CFBundleShortVersionString"] as? String else { return nil }
        return string(short: short, build: info["CFBundleVersion"] as? String ?? "0")
    }
}

/// When to replace the guest agent with the one bundled in the app. Any difference counts (a downgraded app
/// brings its own agent too). Not while the guest is busy, at most once a minute, and after three updates that
/// did not take, not again until the app restarts.
public struct AgentUpdatePolicy: Sendable {
    public static let retryInterval: TimeInterval = 60
    public static let maxFailures = 3

    private var lastAttempt: Date?
    public private(set) var failures = 0

    public init() {}

    public func shouldUpdate(running: String, bundled: String, busy: Bool, now: Date = Date()) -> Bool {
        guard running != bundled, !busy, failures < Self.maxFailures else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retryInterval { return false }
        return true
    }

    public mutating func began(at now: Date = Date()) { lastAttempt = now }

    public mutating func finished(succeeded: Bool) { failures = succeeded ? 0 : failures + 1 }
}
