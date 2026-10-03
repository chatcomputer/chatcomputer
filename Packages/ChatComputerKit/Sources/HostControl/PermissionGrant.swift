#if os(macOS)
import BridgeProtocol
import CoreGraphics
import Foundation

/// Grants the guest agent its two privacy permissions by operating the guest from the host
/// (`HostDisplay`): find the agent's row in the privacy pane, flip its switch, and answer the
/// password prompt with the guest password from the host's secret store. Nothing is guessed blindly:
/// every step looks at the screen first (on-device text recognition), and the result is checked
/// through the agent's own health report.
@MainActor
public struct PermissionGrant {
    public let display: HostDisplay
    /// Asks the guest agent to register itself for the permission and open its settings pane.
    public let prepare: (PermissionKind) async throws -> Void
    /// Whether the agent reports the permission as granted.
    public let isGranted: (PermissionKind) async throws -> Bool
    /// Restarts the guest agent and returns once it has reconnected.
    public let restartAgent: () async throws -> Void
    public let password: () throws -> String
    public let log: (String) -> Void

    public init(display: HostDisplay, prepare: @escaping (PermissionKind) async throws -> Void,
                isGranted: @escaping (PermissionKind) async throws -> Bool,
                restartAgent: @escaping () async throws -> Void,
                password: @escaping () throws -> String, log: @escaping (String) -> Void = { _ in }) {
        self.restartAgent = restartAgent
        self.display = display
        self.prepare = prepare
        self.isGranted = isGranted
        self.password = password
        self.log = log
    }

    nonisolated public static let agentName = "ChatComputerAgent"

    public func run() async throws {
        for kind in [PermissionKind.accessibility, .screenRecording] {
            try await grant(kind)
        }
        // Leave the guest desktop as we found it.
        if let screen = try? read(), screen.contains("System Settings") {
            try await display.key("cmd+q")
        }
    }

    public func grant(_ kind: PermissionKind) async throws {
        if try await isGranted(kind) {
            log("\(kind): already granted")
            return
        }
        log("\(kind): opening its settings pane in the guest")
        try await prepare(kind)
        try await Task.sleep(for: .seconds(2.5))

        var switchClicks = 0
        var idleRounds = 0
        var prepares = 1
        var restarted = false
        for _ in 0..<20 {
            if try await isGranted(kind) {
                log("\(kind): granted")
                return
            }
            let screen = try read()

            // The password prompt that guards the privacy settings.
            if screen.contains("Modify Settings") || (screen.contains("Password") && screen.contains("Cancel")) {
                // The prompt opens with its password field focused and sometimes pre-filled and selected.
                // Clicking it would put the cursor after that text and append to it, so clear it instead
                // (Backspace only: no modifier keys that could linger) and type into the focused field.
                log("\(kind): answering the password prompt")
                for _ in 0..<40 { try await display.key("backspace") }
                try await display.type(try password())
                try await display.key("return")
                try await Task.sleep(for: .seconds(2.5))
                continue
            }
            // Screen recording asks to relaunch the app; the agent's LaunchAgent restarts it.
            if let reopen = screen.first("Quit & Reopen") ?? screen.first("Quit and Reopen") {
                log("\(kind): confirming relaunch of the agent")
                display.click(reopen.center)
                try await Task.sleep(for: .seconds(4))
                continue
            }
            // The system's own consent prompt, shown when the agent asked for the permission.
            if let open = screen.first("Open System Settings") {
                display.click(open.center)
                try await Task.sleep(for: .seconds(2.5))
                continue
            }
            // The pane itself: flip the agent's switch.
            if let row = screen.items.first(where: { $0.text == Self.agentName }) {
                guard let image = display.capture(),
                      let toggle = Self.switchCenter(in: image, guestSize: display.guestSize, row: row.rect,
                                                     rightLimit: Self.paneRightEdge(screen, row: row.rect)) else {
                    throw HostControlError.notFound("the switch next to \(Self.agentName)")
                }
                // Never click a switch that is already on: that would revoke the permission.
                if Self.switchIsOn(in: image, guestSize: display.guestSize, at: toggle) {
                    guard !restarted else { break }
                    log("\(kind): switch is on; restarting the agent so it picks the permission up")
                    try await restartAgent()
                    restarted = true
                    continue
                }
                guard switchClicks < 2 else { break }
                log("\(kind): turning on the switch")
                display.click(toggle)
                switchClicks += 1
                try await Task.sleep(for: .seconds(2.5))
                continue
            }
            // The pane is open but the agent is not listed: its request did not register (seen on a
            // fresh guest for screen recording, right after the TCC reset). Ask again.
            idleRounds += 1
            if idleRounds % 4 == 0, prepares < 3 {
                log("\(kind): the agent is not listed yet; asking again")
                try await prepare(kind)
                prepares += 1
                try await Task.sleep(for: .seconds(2.5))
                continue
            }
            try await Task.sleep(for: .seconds(1.5))
        }
        if try await isGranted(kind) { return }
        throw HostControlError.gaveUp("Could not turn on \(kind) for \(Self.agentName); please do it in the virtual Mac.")
    }

    private func read() throws -> ScreenText {
        guard let image = display.capture() else { throw HostControlError.noFramebuffer }
        return try ScreenText.recognize(image, guestSize: display.guestSize)
    }

    // MARK: Locating the switch

    /// Right edge of the list the row sits in: the widest text block of the pane that starts left of
    /// the row and ends right of it (the pane's description paragraph), else a typical pane width.
    nonisolated public static func paneRightEdge(_ screen: ScreenText, row: CGRect) -> CGFloat {
        let candidates = screen.items.filter { $0.rect.minX <= row.minX + 12 && $0.rect.maxX > row.maxX + 150 && $0.rect.minY < row.minY }
        if let edge = candidates.map(\.rect.maxX).max() { return edge + 4 }
        return row.maxX + 330
    }

    /// Finds a macOS switch in the row's band by its pixels. Each column of the band counts as "ink"
    /// when any pixel in it differs clearly from the list background (the column's median), which
    /// catches the switch's outline even when its fill matches the background, as the off state does.
    /// The rightmost ink run of switch width, scanning from the list's right edge, is the switch.
    nonisolated public static func switchCenter(in image: CGImage, guestSize: CGSize, row: CGRect, rightLimit: CGFloat) -> CGPoint? {
        let scale = CGFloat(image.width) / guestSize.width
        let top = max(0, Int((row.midY - 9) * scale))
        let bottom = min(image.height, Int((row.midY + 9) * scale))
        let left = max(0, Int((row.maxX + 8) * scale))
        let right = min(image.width, Int(rightLimit * scale))
        guard right > left, bottom > top,
              let band = luminance(image, x: left, y: top, width: right - left, height: bottom - top) else { return nil }
        let width = right - left, height = bottom - top

        var ink = [Bool](repeating: false, count: width)
        let backgrounds = (0..<height).map { y in band[(y * width)..<(y * width + width)].sorted()[width / 2] }
        for x in 0..<width {
            for y in 0..<height where abs(band[y * width + x] - backgrounds[y]) > 0.05 {
                ink[x] = true
                break
            }
        }

        // Runs of ink, rightmost first, merging gaps (the knob is separated from the outline).
        let gap = Int(6 * scale)
        var runs: [(Int, Int)] = []
        var x = width - 1
        while x >= 0 {
            guard ink[x] else { x -= 1; continue }
            var start = x
            while start > 0, ink[start - 1] || (start - 1 - gap >= 0 && (start - 1 - gap...start - 1).contains { ink[$0] }) {
                start -= 1
            }
            runs.append((start, x))
            x = start - 1
        }
        guard let capsule = runs.first(where: { CGFloat($0.1 - $0.0) / scale >= 18 && CGFloat($0.1 - $0.0) / scale <= 60 }) else {
            return nil
        }
        return CGPoint(x: (CGFloat(left) + CGFloat(capsule.0 + capsule.1) / 2) / scale, y: row.midY)
    }

    /// An "on" switch is filled with the accent colour; an "off" one is grey. Looks for clearly
    /// saturated pixels across the capsule (the white knob alone is not enough).
    nonisolated public static func switchIsOn(in image: CGImage, guestSize: CGSize, at center: CGPoint) -> Bool {
        let scale = CGFloat(image.width) / guestSize.width
        let rect = CGRect(x: (center.x - 18) * scale, y: (center.y - 6) * scale, width: 36 * scale, height: 12 * scale).integral
        guard let cropped = image.cropping(to: rect) else { return false }
        let width = cropped.width, height = cropped.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var saturated = 0
        for i in 0..<(width * height) {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            if max(r, g, b) - min(r, g, b) > 90 { saturated += 1 }
        }
        return Double(saturated) / Double(width * height) > 0.15
    }

    /// Luminance of a region in row-major order, 0…1.
    nonisolated static func luminance(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) -> [CGFloat]? {
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // CGContext rows run bottom-up; flip so index 0 is the top row.
        return (0..<height).flatMap { row -> [CGFloat] in
            let source = height - 1 - row
            return (0..<width).map { column in
                let i = (source * width + column) * 4
                return (0.2126 * CGFloat(pixels[i]) + 0.7152 * CGFloat(pixels[i + 1]) + 0.0722 * CGFloat(pixels[i + 2])) / 255
            }
        }
    }
}
#endif
