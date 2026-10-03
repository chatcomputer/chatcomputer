#if os(macOS)
import CoreGraphics
import Testing
@testable import HostControl

@Suite struct ConsentPromptTests {
    func item(_ text: String, _ x: CGFloat, _ y: CGFloat) -> ScreenText.Item {
        ScreenText.Item(text: text, rect: CGRect(x: x, y: y, width: 120, height: 16))
    }

    @Test func clicksAllowInTheAgentsPrompt() {
        let screen = ScreenText(items: [
            item("Allow", 900, 40),                    // an unrelated Allow elsewhere, above the dialog
            item("“ChatComputerAgent” is", 400, 200),
            item("requesting to bypass the system", 400, 218),
            item("private window picker and", 400, 236),
            item("Allow", 440, 360),
            item("Open System Settings", 420, 400),
        ])
        #expect(ConsentPrompt.allowButton(in: screen) == CGPoint(x: 500, y: 368))
    }

    @Test func ignoresOtherAppsAndOtherDialogs() {
        let otherApp = ScreenText(items: [item("“Zoom” is requesting to bypass the system", 400, 200), item("Allow", 440, 360)])
        #expect(ConsentPrompt.allowButton(in: otherApp) == nil)
        let nothing = ScreenText(items: [item("ChatComputerAgent", 10, 10), item("Allow", 440, 360)])
        #expect(ConsentPrompt.allowButton(in: nothing) == nil)
    }
}
#endif
