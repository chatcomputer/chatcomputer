#if os(macOS)
import Foundation
import IOSurface
import QuartzCore
import Testing
@testable import HostControl

@MainActor
@Suite struct FramebufferTests {
    @Test func cursorSurfaceBeforeDisplayIsNotTheFramebuffer() throws {
        func surface(_ width: Int, _ height: Int) throws -> IOSurface {
            try #require(IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4]))
        }
        let cursor = try surface(32, 32)
        let guest = try surface(640, 400)
        let root = CALayer()
        let pointer = CALayer(); pointer.contents = cursor
        let display = CALayer(); display.contents = guest
        root.addSublayer(pointer)
        root.addSublayer(display)
        let result = try #require(HostDisplay.framebuffer(in: root))
        #expect(result.width == 640)
        #expect(result.height == 400)
    }
}
#endif
