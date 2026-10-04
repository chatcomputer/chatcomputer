#if os(macOS)
import CoreGraphics
import Foundation

/// Wakes a guest whose screen went to sleep and locked, and types the guest's own password, from the host.
/// Machines installed since 0.2 never lock; older ones still do after a while idle.
public enum GuestUnlock {
    @MainActor
    public static func unlock(on display: HostDisplay, password: String) async throws {
        // A key press wakes a sleeping display even when pointer events don't reach the view (the app in the
        // background, or the host just woken). Escape does nothing on the lock screen itself.
        try await display.key("escape")
        display.move(to: CGPoint(x: display.guestSize.width / 2 - 40, y: display.guestSize.height / 2))
        display.move(to: CGPoint(x: display.guestSize.width / 2, y: display.guestSize.height / 2 + 20))
        // The lock screen fades in and then focuses its password field.
        try await Task.sleep(for: .seconds(3))
        try await display.type(password)
        try await display.key("return")
        try await Task.sleep(for: .seconds(3))
    }
}
#endif
