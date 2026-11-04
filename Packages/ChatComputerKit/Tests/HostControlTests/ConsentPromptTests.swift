#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import HostControl

@Suite struct ConsentPromptTests {
    @Test func recognizesRealCaptureConsentOnMacOS27() throws {
        let url = try #require(Bundle.module.url(forResource: "screen-capture-consent-27", withExtension: "png", subdirectory: "PermissionPanes"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // This is the full host window at 2x, including its setup panel. The
        // unrelated text there must not move the target away from guest Allow.
        let screen = try ScreenText.recognize(image, guestSize: CGSize(width: image.width / 2, height: image.height / 2))
        let point = try #require(ConsentPrompt.allowButton(in: screen))
        #expect((500...780).contains(point.x))
        #expect((495...545).contains(point.y))
    }

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
        let unrelatedAgentRow = ScreenText(items: [
            item("ChatComputerAgent", 10, 10),
            item("Zoom requesting to bypass the system", 400, 240),
            item("Allow", 440, 360),
        ])
        #expect(ConsentPrompt.allowButton(in: unrelatedAgentRow) == nil)
        let nearbyAgentRow = ScreenText(items: [
            item("ChatComputerAgent", 400, 160),
            item("“Zoom” requesting to bypass the system", 400, 200),
            item("Allow", 440, 360),
        ])
        #expect(ConsentPrompt.allowButton(in: nearbyAgentRow) == nil)
    }
}
#endif
