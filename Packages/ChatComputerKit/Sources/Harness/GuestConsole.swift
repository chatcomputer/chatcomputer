#if os(macOS)
import AgentCore
import AppKit
import Carbon.HIToolbox
import CoreImage
import Foundation
import IOSurface
import QuartzCore
import Virtualization

/// Operates the guest from the host, without the guest agent: synthetic NSEvents go straight to the
/// in-process `VZVirtualMachineView`, and screenshots are taken of the harness's own window only.
/// Used for steps that happen before the agent can act (granting it Accessibility / Screen Recording).
///
/// Driven through a command file so an operator (or a script) can look and act step by step:
///
///     <dir>/commands   append one command per line; processed in order
///     <dir>/log        one result line per command
///     <dir>/shot-N.png window screenshots
///
/// Commands (coordinates are guest points, origin top-left):
///     shot | click X Y [COUNT] | rclick X Y | move X Y | drag X1 Y1 X2 Y2 | scroll DY
///     type TEXT | key COMBO | wait SECONDS | done
@MainActor
final class GuestConsole {
    let view: VZVirtualMachineView
    let window: NSWindow
    let directory: URL
    private var processed = 0
    private var shots = 0
    /// How synthesized keys reach the view: "view" (call keyDown), "window" (sendEvent), "pid" (CGEvent to this process).
    private var keyMode = "pid"

    init(view: VZVirtualMachineView, window: NSWindow, directory: URL) {
        self.view = view
        self.window = window
        self.directory = directory
    }

    /// Serves commands until `done`.
    func serve() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let commands = directory.appendingPathComponent("commands")
        if !FileManager.default.fileExists(atPath: commands.path) { try Data().write(to: commands) }
        VMProbe.log("guest console ready: append commands to \(commands.path)")
        while true {
            let lines = (try? String(contentsOf: commands, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
            // Only complete lines (terminated by a newline) are executed.
            let complete = lines.count - 1
            while processed < complete {
                let line = lines[processed].trimmingCharacters(in: .whitespaces)
                processed += 1
                guard !line.isEmpty else { continue }
                if line == "done" { record("done"); return }
                do {
                    record("\(line) → \(try await execute(line))")
                } catch {
                    record("\(line) → ERROR \(error)")
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func record(_ text: String) {
        VMProbe.log("console: \(text)")
        let log = directory.appendingPathComponent("log")
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((text + "\n").utf8).write(to: log)
        }
    }

    func execute(_ line: String) async throws -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts[0]
        let rest = parts.count > 1 ? parts[1] : ""
        let numbers = rest.split(separator: " ").compactMap { Double($0) }
        switch verb {
        case "shot":
            return try await screenshot()
        case "vshot":
            return inProcessCaptureReport()
        case "keymode":
            keyMode = rest
            return "keyMode=\(keyMode)"
        case "keystate":
            focus()
            return "key=\(window.isKeyWindow) firstResponder=\(window.firstResponder === view) active=\(NSApplication.shared.isActive)"
        case "click", "rclick":
            guard numbers.count >= 2 else { throw ProbeError("click X Y") }
            click(at: CGPoint(x: numbers[0], y: numbers[1]), count: numbers.count > 2 ? Int(numbers[2]) : 1, right: verb == "rclick")
        case "move":
            guard numbers.count >= 2 else { throw ProbeError("move X Y") }
            mouse(.mouseMoved, at: CGPoint(x: numbers[0], y: numbers[1]))
        case "drag":
            guard numbers.count >= 4 else { throw ProbeError("drag X1 Y1 X2 Y2") }
            try await drag(from: CGPoint(x: numbers[0], y: numbers[1]), to: CGPoint(x: numbers[2], y: numbers[3]))
        case "scroll":
            guard let dy = numbers.first else { throw ProbeError("scroll DY") }
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0),
               let ns = NSEvent(cgEvent: event) {
                view.scrollWheel(with: ns)
            }
        case "type":
            try await type(rest)
        case "key":
            try await key(rest)
        case "wait":
            try await Task.sleep(for: .seconds(numbers.first ?? 1))
        default:
            throw ProbeError("unknown command \(verb)")
        }
        try await Task.sleep(for: .milliseconds(150))
        return "ok"
    }

    // MARK: Screenshot (own window only)

    func screenshot() async throws -> String {
        shots += 1
        let file = directory.appendingPathComponent(String(format: "shot-%03d.png", shots))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", file.path]
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        guard process.terminationStatus == 0 else { throw ProbeError("screencapture exit \(process.terminationStatus)") }
        return file.lastPathComponent
    }

    // MARK: In-process capture experiments (no Screen Recording permission)

    /// Tries to read the guest framebuffer from the view itself, so the host app can see the guest
    /// without Screen Recording permission on the host. Writes one PNG per method and reports
    /// whether it contains anything but black.
    func inProcessCaptureReport() -> String {
        var report: [String] = []
        func save(_ image: CGImage?, _ name: String) {
            guard let image else { report.append("\(name): nil"); return }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("vshot-\(name).png"))
            report.append("\(name): \(image.width)x\(image.height) nonblack=\(Self.nonBlackFraction(image))")
        }

        // 1. AppKit view cache.
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            save(rep.cgImage, "cacheDisplay")
        }

        // 2. Render the layer tree.
        if let layer = view.layer {
            let scale = window.backingScaleFactor
            let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
            if let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: scale, y: scale)
                layer.render(in: ctx)
                save(ctx.makeImage(), "layerRender")
            }
        }

        // 3. IOSurface contents anywhere in the layer tree.
        var surfaces: [(String, IOSurface)] = []
        func walk(_ layer: CALayer, _ path: String) {
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
                surfaces.append((path + ":" + String(describing: Swift.type(of: layer)), unsafeBitCast(contents as AnyObject, to: IOSurface.self)))
            }
            for (index, sub) in (layer.sublayers ?? []).enumerated() { walk(sub, path + "/\(index)") }
        }
        if let layer = view.layer { walk(layer, "") }
        func describe(_ layer: CALayer, _ depth: Int) -> [String] {
            var lines = [String(repeating: "  ", count: depth) + "\(Swift.type(of: layer)) contents=\(layer.contents.map { String(describing: Swift.type(of: $0)) } ?? "nil") \(Int(layer.bounds.width))x\(Int(layer.bounds.height))"]
            for sub in layer.sublayers ?? [] { lines += describe(sub, depth + 1) }
            return lines
        }
        if let layer = view.layer { report.append("layers:\n" + describe(layer, 1).joined(separator: "\n")) }
        for (index, (path, surface)) in surfaces.enumerated() {
            let ci = CIImage(ioSurface: surface)
            save(CIContext().createCGImage(ci, from: ci.extent), "iosurface\(index)")
            report.append("  surface \(index) at \(path) \(IOSurfaceGetWidth(surface))x\(IOSurfaceGetHeight(surface))")
        }
        if surfaces.isEmpty { report.append("iosurface: none found") }
        return report.joined(separator: "\n")
    }

    static func nonBlackFraction(_ image: CGImage) -> String {
        let width = 64, height = 40
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "?" }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return "?" }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var lit = 0
        for i in 0..<(width * height) where Int(pixels[i * 4]) + Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2]) > 60 { lit += 1 }
        return String(format: "%.2f", Double(lit) / Double(width * height))
    }

    // MARK: Mouse

    /// Guest points (top-left origin) → window coordinates of the view (bottom-left origin).
    private func windowPoint(_ guest: CGPoint) -> CGPoint {
        let bounds = view.bounds
        let size = guestSize
        let local = CGPoint(x: guest.x / size.width * bounds.width, y: bounds.height - guest.y / size.height * bounds.height)
        return view.convert(local, to: nil)
    }

    var guestSize = CGSize(width: 1280, height: 800)

    private func mouse(_ type: NSEvent.EventType, at guest: CGPoint, clickCount: Int = 1) {
        guard let event = NSEvent.mouseEvent(with: type, location: windowPoint(guest), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                                             pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0) else { return }
        switch type {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        default: break
        }
    }

    private func click(at point: CGPoint, count: Int, right: Bool) {
        mouse(.mouseMoved, at: point)
        for index in 1...max(count, 1) {
            mouse(right ? .rightMouseDown : .leftMouseDown, at: point, clickCount: index)
            mouse(right ? .rightMouseUp : .leftMouseUp, at: point, clickCount: index)
        }
    }

    private func drag(from start: CGPoint, to end: CGPoint) async throws {
        mouse(.mouseMoved, at: start)
        mouse(.leftMouseDown, at: start)
        for step in 1...15 {
            let t = Double(step) / 15
            mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            try await Task.sleep(for: .milliseconds(15))
        }
        mouse(.leftMouseUp, at: end)
    }

    // MARK: Keyboard

    private func key(_ combo: String) async throws {
        let (code, flags) = try KeyMap.parse(combo)
        try await press(code, modifiers: Self.modifierFlags(flags), characters: "")
    }

    private func type(_ text: String) async throws {
        for character in text {
            guard let (code, shift) = Self.keystroke(for: character) else { throw ProbeError("cannot type \"\(character)\"") }
            try await press(code, modifiers: shift ? .shift : [], characters: String(character))
        }
    }

    /// The view only forwards keys while it is first responder of the key window.
    private func focus() {
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        if window.firstResponder !== view { window.makeFirstResponder(view) }
    }

    /// Modifier keys with their device-dependent flag bits (IOLLEvent.h NX_DEVICEL*KEYMASK).
    /// The VM view forwards modifier state from flags-changed events and needs these bits.
    private static let modifierKeys: [(flag: NSEvent.ModifierFlags, cgFlag: CGEventFlags, keyCode: Int, device: UInt)] = [
        (.command, .maskCommand, kVK_Command, 0x08),
        (.shift, .maskShift, kVK_Shift, 0x02),
        (.option, .maskAlternate, kVK_Option, 0x20),
        (.control, .maskControl, kVK_Control, 0x01),
    ]

    private func press(_ code: CGKeyCode, modifiers: NSEvent.ModifierFlags, characters: String) async throws {
        focus()
        let used = Self.modifierKeys.filter { modifiers.contains($0.flag) }
        var held: [(flag: NSEvent.ModifierFlags, cgFlag: CGEventFlags, keyCode: Int, device: UInt)] = []
        for key in used {
            held.append(key)
            try await send(keyCode: CGKeyCode(key.keyCode), down: true, held: held, flagsChanged: true, characters: "")
        }
        for down in [true, false] {
            try await send(keyCode: code, down: down, held: held, flagsChanged: false, characters: characters)
        }
        for key in used.reversed() {
            held.removeAll { $0.keyCode == key.keyCode }
            try await send(keyCode: CGKeyCode(key.keyCode), down: false, held: held, flagsChanged: true, characters: "")
        }
    }

    private func send(keyCode: CGKeyCode, down: Bool, held: [(flag: NSEvent.ModifierFlags, cgFlag: CGEventFlags, keyCode: Int, device: UInt)],
                      flagsChanged: Bool, characters: String) async throws {
        var cgFlags = CGEventFlags(rawValue: 0x100) // NX_NONCOALSESCEDMASK, set on real events
        var nsFlags = NSEvent.ModifierFlags(rawValue: 0x100)
        for key in held {
            cgFlags.insert(key.cgFlag)
            cgFlags.insert(CGEventFlags(rawValue: UInt64(key.device)))
            nsFlags.insert(key.flag)
            nsFlags.insert(NSEvent.ModifierFlags(rawValue: key.device))
        }
        if keyMode == "pid" {
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: keyCode, keyDown: down)
            if flagsChanged { event?.type = .flagsChanged }
            event?.flags = cgFlags
            event?.postToPid(getpid())
        } else {
            guard let event = NSEvent.keyEvent(with: flagsChanged ? .flagsChanged : (down ? .keyDown : .keyUp), location: .zero, modifierFlags: nsFlags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false,
                                               keyCode: UInt16(keyCode)) else { return }
            if keyMode == "view" {
                if flagsChanged { view.flagsChanged(with: event) } else if down { view.keyDown(with: event) } else { view.keyUp(with: event) }
            } else {
                window.sendEvent(event)
            }
        }
        try await Task.sleep(for: .milliseconds(25))
    }

    private static func modifierFlags(_ flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        return result
    }

    /// US ANSI layout.
    private static func keystroke(for character: Character) -> (CGKeyCode, Bool)? {
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
#endif
