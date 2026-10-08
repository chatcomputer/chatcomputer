#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import HostControl

@Suite struct PermissionGrantTests {
    /// The Accessibility pane on macOS 26.6.2 with the agent listed and off, captured at 2× (part of the screen).
    @Test func findsTheSwitchOnMacOS26() throws {
        let url = try #require(Bundle.module.url(forResource: "accessibility-26", withExtension: "png", subdirectory: "PermissionPanes"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let guestSize = CGSize(width: image.width / 2, height: image.height / 2)
        let screen = try ScreenText.recognize(image, guestSize: guestSize)
        let row = try #require(screen.items.first { $0.text == PermissionGrant.agentName })

        // The description ends left of the switch: the search must not stop there.
        #expect(PermissionGrant.switchCenter(in: image, guestSize: guestSize, row: row.rect,
                                             rightLimit: PermissionGrant.paneRightEdge(screen, row: row.rect)) == nil)
        let toggle = try #require(PermissionGrant.agentSwitch(in: image, guestSize: guestSize, screen: screen, row: row.rect))
        // The switch spans x 634…671 and sits on the row.
        #expect((634...671).contains(toggle.x))
        #expect(abs(toggle.y - row.rect.midY) < 2)
        #expect(!PermissionGrant.switchIsOn(in: image, guestSize: guestSize, at: toggle))
    }
}
#endif
