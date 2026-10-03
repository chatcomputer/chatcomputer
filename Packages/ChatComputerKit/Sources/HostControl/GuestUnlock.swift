#if os(macOS)
import CoreGraphics
import Foundation

/// Wakes a guest whose screen went to sleep and locked, and types the guest's own password, from the host.
/// Machines installed since 0.2 never lock; older ones still do after a while idle.
public enum GuestUnlock {
    @MainActor
    public static func unlock(on display: HostDisplay, password: String) async throws {
        // Any pointer movement wakes the display; the lock screen then focuses its password field.
        display.move(to: CGPoint(x: display.guestSize.width / 2 - 40, y: display.guestSize.height / 2))
        display.move(to: CGPoint(x: display.guestSize.width / 2, y: display.guestSize.height / 2 + 20))
        try await Task.sleep(for: .seconds(2))
        try await display.type(password)
        try await display.key("return")
        try await Task.sleep(for: .seconds(3))
    }
}
#endif
