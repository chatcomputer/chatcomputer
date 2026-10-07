#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import BridgeProtocol
import CoreGraphics
import ImageIO
import IOKit.pwr_mgt
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Desktop driver using only public macOS APIs. Needs Accessibility (input) and
/// Screen Recording (capture) granted to ChatComputerAgent.app inside the guest.
///
/// Screenshot space = main display in points (1280×800 for the default 2560×1600 @2× VM display),
/// scaled down further only if it would exceed the model's image limits.
public final class NativeDriver: DriverAdapter, @unchecked Sendable {
    public let agentVersion: String
    private let lock = NSLock()
    private var observationVersion = 0
    /// Screenshot pixels per display point; < 1 only for very large displays.
    private var scale: Double = 1

    public init(agentVersion: String) {
        self.agentVersion = agentVersion
    }

    public var capabilities: DriverCapabilities {
        DriverCapabilities(driver: "native", driverVersion: agentVersion, supportsAccessibilityTree: true,
                           supportsBrowserSnapshot: false, supportsBackgroundInput: false)
    }

    public func health() async -> HealthReport {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        // A locked guest usually has its display asleep too, and input from the host doesn't always wake it
        // (seen after the host itself slept). Declaring user activity turns the display on, so the host can
        // type the password into the lock screen.
        if locked || CGDisplayIsAsleep(CGMainDisplayID()) != 0 { Self.wakeDisplay() }
        return HealthReport(
            agentVersion: agentVersion,
            driver: "native",
            hasAquaSession: session?[kCGSessionOnConsoleKey as String] as? Bool ?? false,
            screenLocked: locked,
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            sharedFoldersMounted: FileManager.default.fileExists(atPath: "/Volumes/My Shared Files")
        )
    }

    private static func wakeDisplay() {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Chat Computer: unlocking for the host" as CFString, kIOPMUserActiveLocal, &assertion)
    }

    // MARK: Capture

    public func screenshot(region: ScreenRect?) async throws -> Screenshot {
        guard CGPreflightScreenCaptureAccess() else {
            throw BridgeError(.permissionDenied, "Screen Recording is not granted to ChatComputerAgent.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw BridgeError(.desktopUnavailable, "No display to capture.")
        }

        let pointWidth = display.width
        let pointHeight = display.height
        // SCDisplay sizes are in points; capture at the backing pixel size so zoom has real detail.
        let pixelWidth = CGDisplayCopyDisplayMode(display.displayID)?.pixelWidth ?? pointWidth
        let pixelScale = Double(pixelWidth) / Double(max(pointWidth, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(Double(pointWidth) * pixelScale)
        configuration.height = Int(Double(pointHeight) * pixelScale)
        configuration.showsCursor = true
        let full = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration)

        let limit = Self.limitScale(width: pointWidth, height: pointHeight)
        let outWidth = Int(Double(pointWidth) * limit)
        let outHeight = Int(Double(pointHeight) * limit)
        lock.withLock { scale = limit }

        let image: CGImage
        if let region {
            // Region is in screenshot space; crop at full pixel resolution, then fit into the screenshot size.
            let factor = pixelScale / limit
            let crop = CGRect(x: Double(region.x0) * factor, y: Double(region.y0) * factor,
                              width: Double(region.x1 - region.x0) * factor, height: Double(region.y1 - region.y0) * factor)
            guard let cropped = full.cropping(to: crop) else { throw BridgeError(.invalidCommand, "Zoom region is off screen.") }
            image = try Self.fit(cropped, width: outWidth, height: outHeight)
        } else {
            image = try Self.resize(full, width: outWidth, height: outHeight)
        }

        let version = lock.withLock { observationVersion += 1; return observationVersion }
        return Screenshot(imageData: try Self.png(image), mediaType: "image/png", width: image.width, height: image.height,
                          capturedAt: Date(), observationVersion: version)
    }

    // MARK: Input

    public func perform(_ action: ComputerAction) async throws -> CommandResult {
        if case .wait(let seconds) = action {
            try await Task.sleep(for: .seconds(seconds))
            return .ok
        }
        if case .cursorPosition = action {
            let location = CGEvent(source: nil)?.location ?? .zero
            return .cursor(toScreenshot(location))
        }
        guard AXIsProcessTrusted() else {
            throw BridgeError(.permissionDenied, "Accessibility is not granted to ChatComputerAgent.")
        }
        let source = CGEventSource(stateID: .hidSystemState)

        switch action {
        case .click(let button, let count, let at, let modifiers):
            let location = at.map(toDisplay) ?? currentLocation()
            let flags = try KeyMap.flags(modifiers)
            post(mouse(source, .mouseMoved, at: location, button: .left))
            // Apps track hover before clicks; a click that lands in the same instant as the move can be missed.
            try await Task.sleep(for: .milliseconds(40))
            let held = try await pressModifiers(flags, source: source)
            let (down, up, cgButton) = Self.events(for: button)
            for click in 1...max(count, 1) {
                for type in [down, up] {
                    let event = mouse(source, type, at: location, button: cgButton)
                    event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                    event?.flags = held
                    post(event)
                    try await Task.sleep(for: .milliseconds(type == down ? 30 : 15))
                }
            }
            try await releaseModifiers(flags, source: source)
        case .drag(let from, let to, let modifiers):
            let flags = try KeyMap.flags(modifiers)
            let start = toDisplay(from), end = toDisplay(to)
            post(mouse(source, .mouseMoved, at: start, button: .left))
            post(mouse(source, .leftMouseDown, at: start, button: .left, flags: flags))
            for step in 1...20 {
                let t = Double(step) / 20
                let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                post(mouse(source, .leftMouseDragged, at: point, button: .left, flags: flags))
                try await Task.sleep(for: .milliseconds(10))
            }
            post(mouse(source, .leftMouseUp, at: end, button: .left, flags: flags))
        case .mouseMove(let to):
            post(mouse(source, .mouseMoved, at: toDisplay(to), button: .left))
        case .mouseDown:
            post(mouse(source, .leftMouseDown, at: currentLocation(), button: .left))
        case .mouseUp:
            post(mouse(source, .leftMouseUp, at: currentLocation(), button: .left))
        case .scroll(let direction, let amount, let at, let modifiers):
            if let at { post(mouse(source, .mouseMoved, at: toDisplay(at), button: .left)) }
            let lines = Int32(max(amount, 1))
            let (vertical, horizontal): (Int32, Int32) = switch direction {
            case .up: (lines, 0)
            case .down: (-lines, 0)
            case .left: (0, lines)
            case .right: (0, -lines)
            }
            let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)
            event?.flags = try KeyMap.flags(modifiers)
            post(event)
        case .type(let text):
            try await type(text, source: source)
        case .key(let combo, let repeatCount):
            let (key, flags) = try KeyMap.parse(combo)
            for _ in 0..<repeatCount {
                try await press(key, flags: flags, source: source)
            }
        case .holdKey(let combo, let seconds):
            let (key, flags) = try KeyMap.parse(combo)
            let held = try await pressModifiers(flags, source: source)
            post(keyboard(source, key, down: true, flags: held))
            try await Task.sleep(for: .seconds(seconds))
            post(keyboard(source, key, down: false, flags: held))
            try await releaseModifiers(flags, source: source)
        case .wait, .cursorPosition:
            break
        }
        return .ok
    }

    // MARK: Keyboard

    /// Modifier keys in press order, with the device-dependent flag bits real keyboards set
    /// (IOLLEvent.h NX_DEVICEL*KEYMASK). Some apps, including out-of-process panels such as the
    /// save dialog, read modifier state from these key events rather than from a flag on the key.
    private static let modifierKeys: [(flag: CGEventFlags, keyCode: CGKeyCode, device: UInt64)] = [
        (.maskControl, CGKeyCode(kVK_Control), 0x01),
        (.maskAlternate, CGKeyCode(kVK_Option), 0x20),
        (.maskShift, CGKeyCode(kVK_Shift), 0x02),
        (.maskCommand, CGKeyCode(kVK_Command), 0x08),
    ]

    /// Presses the modifiers in `flags` one by one and returns the flags to put on the main key.
    private func pressModifiers(_ flags: CGEventFlags, source: CGEventSource?) async throws -> CGEventFlags {
        var held = CGEventFlags(rawValue: 0)
        for key in Self.modifierKeys where flags.contains(key.flag) {
            held.insert(key.flag)
            held.insert(CGEventFlags(rawValue: key.device))
            post(keyboard(source, key.keyCode, down: true, flags: held))
            try await Task.sleep(for: .milliseconds(12))
        }
        return held
    }

    private func releaseModifiers(_ flags: CGEventFlags, source: CGEventSource?) async throws {
        var held = CGEventFlags(rawValue: 0)
        for key in Self.modifierKeys where flags.contains(key.flag) {
            held.insert(key.flag)
            held.insert(CGEventFlags(rawValue: key.device))
        }
        for key in Self.modifierKeys.reversed() where flags.contains(key.flag) {
            held.remove(key.flag)
            held.remove(CGEventFlags(rawValue: key.device))
            post(keyboard(source, key.keyCode, down: false, flags: held))
            try await Task.sleep(for: .milliseconds(12))
        }
    }

    /// A full key press: modifiers down, key down and up, modifiers up.
    private func press(_ key: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) async throws {
        let held = try await pressModifiers(flags, source: source)
        post(keyboard(source, key, down: true, flags: held))
        try await Task.sleep(for: .milliseconds(10))
        post(keyboard(source, key, down: false, flags: held))
        try await releaseModifiers(flags, source: source)
        try await Task.sleep(for: .milliseconds(12))
    }

    /// Types text one character at a time: real key presses where the US layout has the character
    /// (these reach every app, including secure fields and out-of-process panels), Unicode events
    /// for the rest (other scripts, emoji). The pause between characters lets the target keep up.
    private func type(_ text: String, source: CGEventSource?) async throws {
        for character in text {
            if let (code, shift) = KeyMap.keystroke(for: character) {
                try await press(code, flags: shift ? .maskShift : [], source: source)
            } else {
                var units = Array(String(character).utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    event?.flags = Self.flags([])
                    post(event)
                }
                try await Task.sleep(for: .milliseconds(15))
            }
        }
    }

    // MARK: Accessibility

    public func uiElements(query: String?) async throws -> UIElementList {
        let factor = lock.withLock { scale }
        return try AccessibilityTree.elements(query: query, scale: factor, display: CGDisplayBounds(CGMainDisplayID()))
    }

    // MARK: Helpers

    private func toDisplay(_ point: ScreenPoint) -> CGPoint {
        let factor = lock.withLock { scale }
        return CGPoint(x: Double(point.x) / factor, y: Double(point.y) / factor)
    }

    private func toScreenshot(_ point: CGPoint) -> ScreenPoint {
        let factor = lock.withLock { scale }
        return ScreenPoint(x: Int(point.x * factor), y: Int(point.y * factor))
    }

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func mouse(_ source: CGEventSource?, _ type: CGEventType, at point: CGPoint, button: CGMouseButton, flags: CGEventFlags = []) -> CGEvent? {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        if !flags.isEmpty { event?.flags = flags }
        return event
    }

    private func keyboard(_ source: CGEventSource?, _ key: CGKeyCode, down: Bool, flags: CGEventFlags) -> CGEvent? {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        event?.flags = Self.flags(flags)
        return event
    }

    /// Bits a real keyboard sets on every event, which CGEvent also sets by default for a HID-state source:
    /// NX_NONCOALESCED (0x100) and 0x20000000. Replacing the flags wholesale dropped them; out-of-process panels such as the save dialog
    /// then ignored plain typing after any Cmd or Ctrl shortcut until the next click (docs/ROADMAP.md §5.1).
    static let preservedFlagBits: UInt64 = 0x2000_0100

    /// `modifiers` on top of the bits every real key event carries.
    static func flags(_ modifiers: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: preservedFlagBits | modifiers.rawValue)
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    private static func events(for button: MouseButton) -> (CGEventType, CGEventType, CGMouseButton) {
        switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .center)
        }
    }

    private static func limitScale(width: Int, height: Int) -> Double {
        // Mirrors ModelProxy.ScreenshotLimits for Claude 5.x models (2576 px long edge, ~3.75 MP).
        let longEdge = 2_576 / Double(max(width, height))
        let area = (3_750_000 / Double(width * height)).squareRoot()
        return min(1, longEdge, area)
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BridgeError(.driverFailure, "Could not create image context.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw BridgeError(.driverFailure, "Could not resize screenshot.") }
        return result
    }

    /// Scales `image` to fit inside width×height, keeping its aspect ratio.
    private static func fit(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let ratio = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        return try resize(image, width: max(1, Int(Double(image.width) * ratio)), height: max(1, Int(Double(image.height) * ratio)))
    }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw BridgeError(.driverFailure, "Could not encode screenshot.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BridgeError(.driverFailure, "Could not encode screenshot.") }
        return data as Data
    }
}
#endif
