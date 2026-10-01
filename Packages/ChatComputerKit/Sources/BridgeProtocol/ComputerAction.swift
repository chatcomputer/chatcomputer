import Foundation

public struct ScreenPoint: Codable, Sendable, Equatable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct ScreenRect: Codable, Sendable, Equatable {
    public var x0: Int
    public var y0: Int
    public var x1: Int
    public var y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }
}

public enum MouseButton: String, Codable, Sendable {
    case left, right, middle
}

public enum ScrollDirection: String, Codable, Sendable {
    case up, down, left, right
}

/// Driver-neutral desktop input. Coordinates are in screenshot pixel space;
/// the guest agent maps them to display points.
///
/// The cases mirror the Claude computer toolset members so the model mapping stays 1:1,
/// but nothing here depends on the model provider.
public enum ComputerAction: Codable, Sendable, Equatable {
    case click(button: MouseButton, count: Int, at: ScreenPoint?, modifiers: [String])
    case drag(from: ScreenPoint, to: ScreenPoint, modifiers: [String])
    case mouseMove(to: ScreenPoint)
    case mouseDown
    case mouseUp
    case cursorPosition
    case scroll(direction: ScrollDirection, amount: Int, at: ScreenPoint?, modifiers: [String])
    /// Literal text, typed as Unicode (works with any guest keyboard layout or input method).
    case type(text: String)
    /// xdotool-style combination, e.g. "Return", "cmd+s", "shift+Tab".
    case key(combo: String, repeat: Int)
    case holdKey(combo: String, seconds: Double)
    case wait(seconds: Double)

    /// Actions that only observe or idle; they still go through the guest but change nothing.
    public var isReadOnly: Bool {
        switch self {
        case .cursorPosition, .wait, .mouseMove: true
        default: false
        }
    }
}
