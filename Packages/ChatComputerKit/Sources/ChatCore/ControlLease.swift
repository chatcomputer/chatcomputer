import Foundation

/// Who may send keyboard/mouse input to the guest. Exactly one holder at a time (proposal §04).
public enum InputHolder: Sendable, Equatable {
    case nobody
    case agent(token: UUID)
    case user
}

/// Single source of truth for input ownership.
///
/// Pause and takeover revoke the agent token *before* anything else happens, so an
/// in-flight model response can no longer dispatch actions with the old token.
public actor ControlLease {
    public private(set) var holder: InputHolder = .nobody

    public init() {}

    /// Grants the agent a fresh token. Fails while the user holds input.
    public func acquireForAgent() throws -> UUID {
        if case .user = holder { throw LeaseError.heldByUser }
        let token = UUID()
        holder = .agent(token: token)
        return token
    }

    public func grantToUser() {
        holder = .user
    }

    public func release() {
        holder = .nobody
    }

    /// Called by the user's explicit "hand back" action only.
    public func releaseFromUser() {
        if case .user = holder { holder = .nobody }
    }

    public func isValid(_ token: UUID) -> Bool {
        if case .agent(let current) = holder { return current == token }
        return false
    }
}

public enum LeaseError: Error, Equatable {
    case heldByUser
    case revoked
}
