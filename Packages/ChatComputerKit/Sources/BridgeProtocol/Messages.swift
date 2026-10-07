import Foundation

/// Constants shared by the host app and the guest agent.
public enum Bridge {
    /// Bumped on any incompatible change to the message types below.
    public static let protocolVersion = 1

    /// vsock port the host listens on; the guest agent connects to the host CID.
    public static let vsockPort: UInt32 = 7_000

    /// Hard cap on a single frame. Screenshots are the largest payload.
    public static let maxFrameBytes = 32 * 1024 * 1024
}

// MARK: - Handshake

/// First frame the guest agent sends after connecting.
public struct GuestHello: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var agentVersion: String
    /// Identity the host assigned to this VM during bootstrap. `nil` before pairing.
    public var vmID: UUID?
    /// One-time secret written into the guest during bootstrap; proves this is the VM we provisioned.
    public var pairingToken: String?
    public var osVersion: String

    public init(protocolVersion: Int = Bridge.protocolVersion, agentVersion: String, vmID: UUID?, pairingToken: String?, osVersion: String) {
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.vmID = vmID
        self.pairingToken = pairingToken
        self.osVersion = osVersion
    }
}

public struct HostWelcome: Codable, Sendable, Equatable {
    public var accepted: Bool
    public var vmID: UUID
    public var reason: String?

    public init(accepted: Bool, vmID: UUID, reason: String? = nil) {
        self.accepted = accepted
        self.vmID = vmID
        self.reason = reason
    }
}

// MARK: - Commands

/// Every command carries enough context for the guest to reject stale or unauthorized work.
public struct CommandEnvelope: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var vmID: UUID
    public var jobID: UUID?
    public var commandID: UUID
    /// Agent input lease. Input commands without a valid lease are rejected by the host before sending,
    /// and the guest double-checks it against the last lease the host announced.
    public var leaseToken: UUID?
    /// Observation the action was planned against, so stale coordinates can be detected.
    public var observationVersion: Int?
    public var deadline: Date
    public var command: GuestCommand

    public init(vmID: UUID, jobID: UUID?, commandID: UUID = UUID(), leaseToken: UUID?, observationVersion: Int?, deadline: Date, command: GuestCommand) {
        self.protocolVersion = Bridge.protocolVersion
        self.vmID = vmID
        self.jobID = jobID
        self.commandID = commandID
        self.leaseToken = leaseToken
        self.observationVersion = observationVersion
        self.deadline = deadline
        self.command = command
    }
}

public enum GuestCommand: Codable, Sendable, Equatable {
    case health
    case capabilities
    /// Full-screen capture, or a region in screenshot coordinates (the computer toolset's `zoom`).
    case screenshot(region: ScreenRect?)
    case perform(ComputerAction)
    /// Announces the current agent lease (or `nil` when the user holds input).
    case setLease(UUID?)
    case cancel(commandID: UUID)
    /// Clean guest shutdown. The VM's own stop request only opens a "Shut down?" dialog in a
    /// macOS guest and never completes on its own, so the agent shuts down from inside.
    case shutdown
    /// Registers the agent for a privacy permission and opens that settings pane in the guest.
    /// Needs no permission itself; the host then flips the switch (see `HostControl.PermissionGrant`).
    case preparePermission(PermissionKind)
    /// The agent answers, then exits; its LaunchAgent (KeepAlive) starts it again and it reconnects.
    /// Used when a permission was granted but the running process does not see it yet.
    case restartAgent
    /// Replace the agent with the copy in the bootstrap share, if it carries a valid signature from the
    /// same team, then restart. SSH is off after setup, so this is how a newer agent gets in.
    case updateAgent
    /// The interactive elements of the frontmost app (its windows, sheets and menu bar) from the guest's
    /// accessibility tree, optionally filtered. Read-only: needs Accessibility but not the input lease.
    /// Only sent when `DriverCapabilities.supportsAccessibilityTree` is true.
    case uiElements(query: String?)
    /// The text of the frontmost app's focused window (and its sheets) in reading order: headings, paragraphs,
    /// table rows, field values, including what is scrolled out of view. Read-only, like `uiElements`.
    case uiText

    /// Whether the command synthesizes input in the guest and so needs the agent lease.
    public var requiresLease: Bool {
        if case .perform = self { return true }
        return false
    }
}

/// The two guest privacy permissions the agent needs.
public enum PermissionKind: String, Codable, Sendable, CaseIterable, CustomStringConvertible {
    case accessibility      // "Device Control and Data Access" on macOS 27: input
    case screenRecording    // capture

    /// The TCC service name, as `tccutil` spells it.
    public var tccService: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "ScreenCapture"
        }
    }

    public var description: String {
        switch self {
        case .accessibility: "device control"
        case .screenRecording: "screen recording"
        }
    }
}

// MARK: - Responses

public struct ResponseEnvelope: Codable, Sendable, Equatable {
    public var commandID: UUID
    public var result: CommandResult

    public init(commandID: UUID, result: CommandResult) {
        self.commandID = commandID
        self.result = result
    }
}

public enum CommandResult: Codable, Sendable, Equatable {
    case ok
    case screenshot(Screenshot)
    case cursor(ScreenPoint)
    case health(HealthReport)
    case capabilities(DriverCapabilities)
    case elements(UIElementList)
    case text(UIText)
    case failure(BridgeError)
}

/// One control from the guest's accessibility tree, located in screenshot space.
public struct UIElement: Codable, Sendable, Equatable {
    /// Its position in this list; `click_element` refers to it by this number.
    public var id: Int
    /// The AX role without its prefix: "button", "textfield", "menuitem", "checkbox", …
    public var role: String
    /// What a person would call it: the title, description, label or placeholder, whichever exists first.
    public var name: String
    /// The current value of a text field, checkbox or popup, when it has one.
    public var value: String?
    public var enabled: Bool
    public var frame: ScreenRect

    public init(id: Int, role: String, name: String, value: String?, enabled: Bool, frame: ScreenRect) {
        self.id = id
        self.role = role
        self.name = name
        self.value = value
        self.enabled = enabled
        self.frame = frame
    }

    public var center: ScreenPoint { ScreenPoint(x: (frame.x0 + frame.x1) / 2, y: (frame.y0 + frame.y1) / 2) }
}

/// The readable text of the window in front, from the accessibility tree.
public struct UIText: Codable, Sendable, Equatable {
    public var app: String
    /// The window's title, when it has one.
    public var window: String?
    /// One line per heading, paragraph, table row or field; headings start with "# ", rows join cells with " | ".
    public var lines: [String]
    /// The window had more text than fits.
    public var truncated: Bool

    public init(app: String, window: String?, lines: [String], truncated: Bool) {
        self.app = app
        self.window = window
        self.lines = lines
        self.truncated = truncated
    }
}

public struct UIElementList: Codable, Sendable, Equatable {
    /// The frontmost app, e.g. "TextEdit".
    public var app: String
    public var elements: [UIElement]
    /// More elements matched than were returned.
    public var truncated: Bool

    public init(app: String, elements: [UIElement], truncated: Bool) {
        self.app = app
        self.elements = elements
        self.truncated = truncated
    }
}

public struct Screenshot: Codable, Sendable, Equatable {
    /// PNG or JPEG bytes. `Data` encodes as base64 in JSON.
    public var imageData: Data
    public var mediaType: String
    public var width: Int
    public var height: Int
    public var capturedAt: Date
    /// Monotonic counter the guest bumps per capture; actions reference it.
    public var observationVersion: Int

    public init(imageData: Data, mediaType: String, width: Int, height: Int, capturedAt: Date, observationVersion: Int) {
        self.imageData = imageData
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
        self.observationVersion = observationVersion
    }
}

public struct HealthReport: Codable, Sendable, Equatable {
    public var agentVersion: String
    public var driver: String
    public var hasAquaSession: Bool
    public var screenLocked: Bool
    public var accessibilityGranted: Bool
    public var screenRecordingGranted: Bool
    public var sharedFoldersMounted: Bool

    public init(agentVersion: String, driver: String, hasAquaSession: Bool, screenLocked: Bool, accessibilityGranted: Bool, screenRecordingGranted: Bool, sharedFoldersMounted: Bool) {
        self.agentVersion = agentVersion
        self.driver = driver
        self.hasAquaSession = hasAquaSession
        self.screenLocked = screenLocked
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.sharedFoldersMounted = sharedFoldersMounted
    }

    /// The readiness probe from the proposal (§06): desktop usable, not just SSH reachable.
    public var isDesktopReady: Bool {
        hasAquaSession && !screenLocked && accessibilityGranted && screenRecordingGranted
    }
}

public struct DriverCapabilities: Codable, Sendable, Equatable {
    public var driver: String
    public var driverVersion: String
    public var supportsAccessibilityTree: Bool
    public var supportsBrowserSnapshot: Bool
    public var supportsBackgroundInput: Bool

    public init(driver: String, driverVersion: String, supportsAccessibilityTree: Bool, supportsBrowserSnapshot: Bool, supportsBackgroundInput: Bool) {
        self.driver = driver
        self.driverVersion = driverVersion
        self.supportsAccessibilityTree = supportsAccessibilityTree
        self.supportsBrowserSnapshot = supportsBrowserSnapshot
        self.supportsBackgroundInput = supportsBackgroundInput
    }
}

public struct BridgeError: Error, Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable {
        case permissionDenied     // TCC grant missing in the guest
        case desktopUnavailable   // locked, logged out, no Aqua session
        case leaseRejected        // input without a valid lease
        case staleObservation     // action planned against an outdated screenshot
        case deadlineExceeded
        case cancelled
        case invalidCommand
        case driverFailure
        case protocolMismatch
    }

    public var category: Category
    public var message: String

    public init(_ category: Category, _ message: String) {
        self.category = category
        self.message = message
    }
}

// MARK: - Framing

/// Host → guest frames.
public enum HostMessage: Codable, Sendable, Equatable {
    case welcome(HostWelcome)
    case command(CommandEnvelope)
}

/// Guest → host frames.
public enum GuestMessage: Codable, Sendable, Equatable {
    case hello(GuestHello)
    case response(ResponseEnvelope)
}

extension BridgeError: LocalizedError {
    /// The guest's own message, so "error 1" never reaches the user.
    public var errorDescription: String? { message }
}
