import Foundation

/// The host's view of a connected guest agent.
///
/// `GuestBridge.BridgeServer` implements it over vsock; tests use an in-memory fake.
/// Callers never see sockets, so the orchestrator stays testable off-Mac.
public protocol GuestChannel: Sendable {
    var vmID: UUID { get }
    func send(_ envelope: CommandEnvelope) async throws -> CommandResult
}
