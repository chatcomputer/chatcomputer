#if os(macOS)
import Foundation
import BridgeProtocol

/// What the guest agent needs from a desktop driver. Swapping drivers changes nothing on the host:
/// task store, approvals and UI state all sit above this protocol (proposal §05).
///
/// Implementations:
/// - `NativeDriver`: ScreenCaptureKit + CGEvent + Accessibility. Small, one signing identity; the fallback.
/// - Cua Driver (planned, probe P6): launched in *embedded* mode as a private daemon of this app so it
///   inherits this app's TCC grants. Adds background (no focus steal) input, AX trees and browser
///   semantic snapshots. Its tool names must come from the pinned Cua version, so no adapter is
///   written until P6 has run against a real macOS 27 guest.
public protocol DriverAdapter: Sendable {
    var capabilities: DriverCapabilities { get }
    func health() async -> HealthReport
    /// Captures the main display in screenshot space, or a region of it scaled up to fill that space.
    func screenshot(region: ScreenRect?) async throws -> Screenshot
    func perform(_ action: ComputerAction) async throws -> CommandResult
    /// The frontmost app's interactive elements in screenshot space, filtered by `query` when given.
    func uiElements(query: String?) async throws -> UIElementList
    /// The focused window's text in reading order.
    func uiText() async throws -> UIText
}
#endif
