#if os(macOS)
import AppKit
import HostControl

/// Offline check of PermissionGrant's screen reading on a saved guest screenshot:
///     cc-harness find-switch IMAGE [GUEST_WIDTH GUEST_HEIGHT]
enum SwitchProbe {
    static func run(arguments: [String]) -> Int32 {
        guard let path = arguments.first, let source = NSImage(contentsOfFile: path),
              let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("usage: cc-harness find-switch IMAGE [GUEST_WIDTH GUEST_HEIGHT]")
            return 2
        }
        let guest = arguments.count >= 3 ? CGSize(width: Double(arguments[1])!, height: Double(arguments[2])!)
                                          : CGSize(width: image.width / 2, height: image.height / 2)
        do {
            let screen = try ScreenText.recognize(image, guestSize: guest)
            guard let row = screen.items.first(where: { $0.text == PermissionGrant.agentName }) else {
                print("row not found; text seen: \(screen.items.prefix(30).map(\.text))")
                return 1
            }
            let edge = PermissionGrant.paneRightEdge(screen, row: row.rect)
            print("row \(row.rect.integral) paneRightEdge \(Int(edge))")
            if let point = PermissionGrant.switchCenter(in: image, guestSize: guest, row: row.rect, rightLimit: edge) {
                print("switch at \(Int(point.x)), \(Int(point.y)) on=\(PermissionGrant.switchIsOn(in: image, guestSize: guest, at: point))")
                return 0
            }
            print("switch not found")
            return 1
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}
#endif
