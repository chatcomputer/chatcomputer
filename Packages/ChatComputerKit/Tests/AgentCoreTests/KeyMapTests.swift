#if os(macOS)
import BridgeProtocol
import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import AgentCore

@Suite struct KeyMapTests {
    @Test func parsesCombosAndNamedKeys() throws {
        let (save, saveFlags) = try KeyMap.parse("cmd+shift+S")
        #expect(save == CGKeyCode(kVK_ANSI_S))
        #expect(saveFlags == [.maskCommand, .maskShift])

        let (tab, tabFlags) = try KeyMap.parse("super+Tab")
        #expect(tab == CGKeyCode(kVK_Tab))
        #expect(tabFlags == .maskCommand)

        #expect(try KeyMap.parse("Return").0 == CGKeyCode(kVK_Return))
        #expect(try KeyMap.parse("ctrl + alt + Delete") == (CGKeyCode(kVK_ForwardDelete), [.maskControl, .maskAlternate]))
        #expect(try KeyMap.parse("Page_Down").0 == CGKeyCode(kVK_PageDown))
        #expect(try KeyMap.parse("/").0 == CGKeyCode(kVK_ANSI_Slash))
    }

    @Test func rejectsUnknownKeysAndModifiers() {
        #expect(throws: BridgeError.self) { try KeyMap.parse("cmd+launch") }
        #expect(throws: BridgeError.self) { try KeyMap.parse("hyper+a") }
        #expect(throws: BridgeError.self) { try KeyMap.parse("") }
    }
}
#endif
