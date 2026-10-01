#if os(macOS)
import AppKit
import BridgeProtocol
import Foundation

/// A simulated guest for live model tests: renders a 1280×800 desktop with one "Notes" window.
/// Clicking the text area focuses it, `type` inserts text, ⌘S or the Save button writes
/// the text to `note.txt` in the job's outbox. Nothing touches the real host desktop.
actor FakeDesktop: GuestChannel {
    nonisolated let vmID = UUID()
    static let size = (width: 1280, height: 800)
    static let textArea = CGRect(x: 140, y: 150, width: 1000, height: 520)
    static let saveButton = CGRect(x: 1040, y: 98, width: 100, height: 36)

    private let outbox: @Sendable () -> URL?
    private let screenshotDirectory: URL?
    private var text = ""
    private var focused = false
    private var allSelected = false
    private var savedName: String?
    private var version = 0
    private(set) var log: [String] = []

    private let guestOutboxPath: @Sendable () -> String

    init(initialText: String = "", outbox: @escaping @Sendable () -> URL?, guestOutboxPath: @escaping @Sendable () -> String, screenshotDirectory: URL?) {
        self.text = initialText
        self.outbox = outbox
        self.guestOutboxPath = guestOutboxPath
        self.screenshotDirectory = screenshotDirectory
    }

    func send(_ envelope: CommandEnvelope) async throws -> CommandResult {
        switch envelope.command {
        case .setLease, .cancel:
            return .ok
        case .health, .capabilities:
            return .ok
        case .screenshot:
            version += 1
            let png = try render()
            if let screenshotDirectory {
                try? png.write(to: screenshotDirectory.appendingPathComponent(String(format: "shot-%03d.png", version)))
            }
            log.append("screenshot #\(version)")
            return .screenshot(Screenshot(imageData: png, mediaType: "image/png", width: Self.size.width, height: Self.size.height,
                                          capturedAt: Date(), observationVersion: version))
        case .perform(let action):
            log.append("\(action)")
            return try perform(action)
        }
    }

    private func perform(_ action: ComputerAction) throws -> CommandResult {
        switch action {
        case .click(_, _, let at, _):
            guard let at else { return .ok }
            let point = CGPoint(x: at.x, y: at.y)
            if Self.saveButton.contains(point) {
                try save()
            } else {
                focused = Self.textArea.contains(point)
                allSelected = false
            }
        case .type(let typed):
            if focused {
                if allSelected { text = "" }
                text += typed
                allSelected = false
            }
        case .key(let combo, let count):
            let normalized = combo.lowercased().replacingOccurrences(of: "command", with: "cmd").replacingOccurrences(of: "super", with: "cmd")
            for _ in 0..<count {
                switch normalized {
                case "cmd+s": try save()
                case "return", "enter": if focused { text += "\n"; allSelected = false }
                case "backspace", "delete":
                    if focused, allSelected { text = ""; allSelected = false } else if focused, !text.isEmpty { text.removeLast() }
                case "cmd+a": if focused { allSelected = true }
                default: break
                }
            }
        case .cursorPosition:
            return .cursor(ScreenPoint(x: 0, y: 0))
        default:
            break
        }
        return .ok
    }

    private func save() throws {
        guard let directory = outbox() else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: directory.appendingPathComponent("note.txt"))
        savedName = "note.txt"
    }

    var savedText: String? {
        guard let directory = outbox() else { return nil }
        return try? String(contentsOf: directory.appendingPathComponent("note.txt"), encoding: .utf8)
    }

    // MARK: Rendering

    private func render() throws -> Data {
        let (width, height) = Self.size
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.featureUnsupported) }
        // Flip to top-left origin so drawing matches screen coordinates.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.65, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()
        // Menu bar
        NSColor(white: 0.95, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: width, height: 28).fill()
        draw("  Notes    File    Edit    Format    Window    Help", at: CGPoint(x: 8, y: 6), size: 14, weight: .medium)

        // Window
        let window = CGRect(x: 120, y: 70, width: 1040, height: 620)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: window, xRadius: 10, yRadius: 10).fill()
        NSColor(white: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: window.minX, y: window.minY, width: window.width, height: 72), xRadius: 10, yRadius: 10).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: window.minX + 14 + CGFloat(index) * 22, y: window.minY + 12, width: 13, height: 13)).fill()
        }
        let title = savedName.map { "\($0) — Notes (saved)" } ?? "Untitled — Notes (not saved)"
        draw(title, at: CGPoint(x: window.midX - 140, y: window.minY + 10), size: 15, weight: .semibold)

        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: Self.saveButton, xRadius: 6, yRadius: 6).fill()
        draw("Save", at: CGPoint(x: Self.saveButton.minX + 30, y: Self.saveButton.minY + 8), size: 16, weight: .semibold, color: .white)

        // Text area
        NSColor(white: 0.98, alpha: 1).setFill()
        Self.textArea.fill()
        (focused ? NSColor.systemBlue : NSColor(white: 0.75, alpha: 1)).setStroke()
        let border = NSBezierPath(rect: Self.textArea)
        border.lineWidth = focused ? 3 : 1
        border.stroke()
        if text.isEmpty && !focused {
            draw("Click here to start typing…", at: CGPoint(x: Self.textArea.minX + 16, y: Self.textArea.minY + 14), size: 20, color: .gray)
        } else {
            if allSelected {
                NSColor.selectedTextBackgroundColor.setFill()
                CGRect(x: Self.textArea.minX + 12, y: Self.textArea.minY + 12, width: 600, height: 28 * CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count)).fill()
            }
            draw(text + (focused ? "▏" : ""), at: CGPoint(x: Self.textArea.minX + 16, y: Self.textArea.minY + 14), size: 20)
        }
        let status = savedName.map { "Saved to \(guestOutboxPath())/\($0)" } ?? (focused ? "Editing" : "Not focused")
        draw(status, at: CGPoint(x: window.minX + 20, y: window.maxY - 18), size: 13, color: .darkGray)

        guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.featureUnsupported) }
        return png
    }

    private func draw(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        NSAttributedString(string: string, attributes: attributes).draw(at: point)
    }
}
#endif
