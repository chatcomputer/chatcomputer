#if os(macOS)
import CoreGraphics
import Foundation

/// macOS asks again, from time to time, whether an app that captures the screen with ScreenCaptureKit may keep
/// "bypassing the system private window picker". Until someone answers, the dialog covers the guest's screen
/// and the agent can't work. It concerns only our own guest agent, whose permissions onboarding already granted
/// from the host, so the host answers it the same way: it reads the guest screen and clicks Allow.
public enum ConsentPrompt {
    /// Where to click Allow, if the screen shows this prompt for the guest agent.
    public static func allowButton(in screen: ScreenText) -> CGPoint? {
        let text = screen.items.map(\.text).joined(separator: " ").lowercased()
        guard text.contains("chatcomputeragent"), text.contains("private window picker") || text.contains("requesting to bypass") else { return nil }
        guard let prompt = screen.first("requesting to bypass") ?? screen.first("private window picker") else { return nil }
        // The Allow button sits below the prompt's text, in the same dialog.
        return screen.items
            .filter { $0.text.trimmingCharacters(in: .whitespaces).lowercased() == "allow" && $0.rect.minY > prompt.rect.minY
                && abs($0.rect.midX - prompt.rect.midX) < 300 }
            .min { $0.rect.minY < $1.rect.minY }?
            .center
    }

    /// Reads the guest screen and answers the prompt if it is showing. Returns whether it clicked.
    @MainActor
    public static func approveIfShown(on display: HostDisplay) async -> Bool {
        guard let image = display.capture() else { return false }
        let size = display.guestSize
        let point = await Task.detached { () -> CGPoint? in
            guard let screen = try? ScreenText.recognize(image, guestSize: size) else { return nil }
            return allowButton(in: screen)
        }.value
        guard let point else { return false }
        display.click(point)
        return true
    }
}
#endif
