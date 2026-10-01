import Foundation

/// The task states from the proposal (§04). The UI is derived from this, never from chat text.
public enum TaskPhase: Codable, Sendable, Equatable {
    case ready
    case running
    case waitingForUser(reason: String)
    case waitingExternal(reason: String, until: Date?)
    case paused
    case takenOver
    case failed(reason: String)
    case completed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .failed, .completed, .cancelled: true
        default: false
        }
    }

    /// Only these phases allow the orchestrator to dispatch new guest actions.
    public var allowsDispatch: Bool {
        self == .running
    }
}

public enum TaskTrigger: Sendable, Equatable {
    case start
    case pause
    case resume
    /// The user grabbed keyboard/mouse in the VM view.
    case userTookOver
    /// The user explicitly handed control back; never automatic.
    case userReturnedControl
    case needUser(String)
    case userResolved
    case waitExternal(String, until: Date?)
    case externalResolved
    case cancel
    case fail(String)
    case complete
}

public struct InvalidTransition: Error, Equatable, CustomStringConvertible {
    public let from: TaskPhase
    public let trigger: String

    public var description: String { "Invalid transition from \(from) on \(trigger)" }
}

extension TaskPhase {
    /// Pure transition function; persisted before any side effect happens.
    public func applying(_ trigger: TaskTrigger) throws -> TaskPhase {
        switch (self, trigger) {
        case (.ready, .start):
            return .running

        case (_, .cancel) where !isTerminal:
            return .cancelled
        case (_, .fail(let reason)) where !isTerminal:
            return .failed(reason: reason)

        // Takeover is allowed from any live phase and always wins.
        case (.running, .userTookOver), (.paused, .userTookOver),
             (.waitingForUser, .userTookOver), (.waitingExternal, .userTookOver):
            return .takenOver
        // Handing control back lands in paused, so the agent re-observes before acting.
        case (.takenOver, .userReturnedControl):
            return .paused

        case (.running, .pause), (.waitingExternal, .pause):
            return .paused
        case (.paused, .resume):
            return .running

        case (.running, .needUser(let reason)):
            return .waitingForUser(reason: reason)
        case (.waitingForUser, .userResolved):
            return .running

        case (.running, .waitExternal(let reason, let until)):
            return .waitingExternal(reason: reason, until: until)
        case (.waitingExternal, .externalResolved):
            return .running

        case (.running, .complete):
            return .completed

        default:
            throw InvalidTransition(from: self, trigger: String(describing: trigger))
        }
    }
}
