#if os(macOS)
import AgentCore
import AppKit
import Carbon.HIToolbox
import CoreImage
import IOSurface
import Virtualization

/// Host-level control of the guest: reads the guest framebuffer from the app's own
/// `VZVirtualMachineView` and feeds it mouse and keyboard events, like a monitor, keyboard and
/// mouse plugged into the virtual Mac.
///
/// It needs nothing inside the guest (no agent, no permissions) and no Screen Recording permission
/// on the host, because it only reads the app's own view. The guest agent remains the tool for
/// everyday work; this is for what happens before the agent can act, such as granting it permissions.
///
/// Coordinates are guest points with a top-left origin (1280×800 for the default display).
@MainActor
public final class HostDisplay {
    public let view: VZVirtualMachineView
    public var guestSize: CGSize

    public init(view: VZVirtualMachineView, guestSize: CGSize) {
        self.view = view
        self.guestSize = guestSize
    }

    // MARK: Screen

    /// The current guest framebuffer at full pixel resolution.
    ///
    /// The view keeps the framebuffer in an IOSurface on one of its layers (macOS 27); reading it is
    /// the cheapest path and returns exactly what the guest drew. AppKit's view cache is the fallback.
    public func capture() -> CGImage? {
        if let surface = Self.framebuffer(in: view.layer) {
            let image = CIImage(ioSurface: surface)
            if let cgImage = CIContext().createCGImage(image, from: image.extent) { return cgImage }
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private static func framebuffer(in layer: CALayer?) -> IOSurface? {
        guard let layer else { return nil }
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            return unsafeBitCast(contents as AnyObject, to: IOSurface.self)
        }
        for sublayer in layer.sublayers ?? [] {
            if let surface = framebuffer(in: sublayer) { return surface }
        }
        return nil
    }

    // MARK: Mouse

    public func click(_ point: CGPoint, count: Int = 1) {
        mouse(.mouseMoved, at: point)
        for index in 1...max(count, 1) {
            mouse(.leftMouseDown, at: point, clickCount: index)
            mouse(.leftMouseUp, at: point, clickCount: index)
        }
    }

    public func move(to point: CGPoint) {
        mouse(.mouseMoved, at: point)
    }

    /// Guest points (top-left origin) → window coordinates (bottom-left origin).
    private func windowPoint(_ guest: CGPoint) -> CGPoint {
        let bounds = view.bounds
        let local = CGPoint(x: guest.x / guestSize.width * bounds.width,
                            y: bounds.height - guest.y / guestSize.height * bounds.height)
        return view.convert(local, to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at guest: CGPoint, clickCount: Int = 1) {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: type, location: windowPoint(guest), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: clickCount,
                                             pressure: type == .leftMouseDown ? 1 : 0) else { return }
        switch type {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: break
        }
    }

    // MARK: Keyboard

    /// Types text on a US layout. Used for secrets too, so it never logs what it types.
    public func type(_ text: String) async throws {
        for character in text {
            guard let (code, shift) = Self.keystroke(for: character) else { throw HostControlError.untypable }
            try await press(code, modifiers: shift ? [.shift] : [], characters: String(character))
        }
    }

    /// Key combination such as "return", "cmd+q" or "shift+tab".
    public func key(_ combo: String) async throws {
        let (code, flags) = try KeyMap.parse(combo)
        var modifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        try await press(code, modifiers: modifiers, characters: "")
    }

    /// Modifier keys with their device-dependent flag bits (IOLLEvent.h NX_DEVICEL*KEYMASK).
    /// The VM view takes modifier state from flags-changed events and ignores them without these bits.
    private static let modifierKeys: [(flag: NSEvent.ModifierFlags, keyCode: Int, device: UInt)] = [
        (.command, kVK_Command, 0x08),
        (.shift, kVK_Shift, 0x02),
        (.option, kVK_Option, 0x20),
        (.control, kVK_Control, 0x01),
    ]

    private func press(_ code: CGKeyCode, modifiers: NSEvent.ModifierFlags, characters: String) async throws {
        // The view only forwards keys while it is the first responder of the key window.
        guard let window = view.window else { throw HostControlError.noWindow }
        if !window.isKeyWindow {
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
        }
        if window.firstResponder !== view { window.makeFirstResponder(view) }

        let used = Self.modifierKeys.filter { modifiers.contains($0.flag) }
        var held: [(flag: NSEvent.ModifierFlags, keyCode: Int, device: UInt)] = []
        for key in used {
            held.append(key)
            try await send(window, keyCode: CGKeyCode(key.keyCode), type: .flagsChanged, held: held, characters: "")
        }
        try await send(window, keyCode: code, type: .keyDown, held: held, characters: characters)
        try await send(window, keyCode: code, type: .keyUp, held: held, characters: characters)
        for key in used.reversed() {
            held.removeAll { $0.keyCode == key.keyCode }
            try await send(window, keyCode: CGKeyCode(key.keyCode), type: .flagsChanged, held: held, characters: "")
        }
    }

    private func send(_ window: NSWindow, keyCode: CGKeyCode, type: NSEvent.EventType,
                      held: [(flag: NSEvent.ModifierFlags, keyCode: Int, device: UInt)], characters: String) async throws {
        var flags = NSEvent.ModifierFlags(rawValue: 0x100) // NX_NONCOALSESCEDMASK, set on real events
        for key in held {
            flags.insert(key.flag)
            flags.insert(NSEvent.ModifierFlags(rawValue: key.device))
        }
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(),
                                           isARepeat: false, keyCode: UInt16(keyCode)) else { return }
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(25))
    }

    /// US ANSI layout: key code and whether Shift is needed.
    static func keystroke(for character: Character) -> (CGKeyCode, Bool)? {
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
        ]
        if character == " " { return (CGKeyCode(kVK_Space), false) }
        if character == "\n" { return (CGKeyCode(kVK_Return), false) }
        if let base = shifted[character], let code = KeyMap.code(for: String(base)) { return (code, true) }
        if character.isUppercase, let code = KeyMap.code(for: character.lowercased()) { return (code, true) }
        if let code = KeyMap.code(for: String(character)) { return (code, false) }
        return nil
    }
}

public enum HostControlError: Error, Equatable, CustomStringConvertible {
    case noWindow
    case noFramebuffer
    case untypable
    case notFound(String)
    case gaveUp(String)

    public var description: String {
        switch self {
        case .noWindow: "The virtual Mac is not on screen."
        case .noFramebuffer: "Could not read the virtual Mac's screen."
        case .untypable: "Text contains a character that cannot be typed on a US keyboard layout."
        case .notFound(let what): "Could not find \(what) on the virtual Mac's screen."
        case .gaveUp(let detail): detail
        }
    }
}
#endif
