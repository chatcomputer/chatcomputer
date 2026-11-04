#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import BridgeProtocol
import Testing
@testable import HostControl

@Suite struct PermissionGrantTests {
    @MainActor
    @Test func rowAndSwitchUseTheSameActualFrame() async throws {
        let url = try #require(Bundle.module.url(forResource: "screen-recording-off-27", withExtension: "png", subdirectory: "PermissionPanes"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let display = ChangingPermissionDisplay(image: image)
        let grant = PermissionGrant(display: display, prepare: { _ in }, isGranted: { _ in display.clicked },
                                    restartAgent: { Issue.record("An off switch must not restart the agent") },
                                    password: { "unused" }, sleep: { _ in await Task.yield() })
        try await grant.grant(.screenRecording)
        #expect(display.clicked)
        #expect(display.captures == 1)
    }

    func pendingControlImage() throws -> CGImage {
        let url = try #require(Bundle.module.url(forResource: "pending-control-consent-27", withExtension: "png", subdirectory: "PermissionPanes"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test func recognizesTheAlreadyGrantedControlAlertInTheActualFailureFrame() throws {
        let image = try pendingControlImage()
        let screen = try ScreenText.recognize(image, guestSize: CGSize(width: image.width / 2, height: image.height / 2))
        let point = try #require(PermissionGrant.initialConsentButton(in: screen, kind: .accessibility))
        #expect((600...780).contains(point.x))
        #expect((330...420).contains(point.y))
        #expect(PermissionGrant.initialConsentButton(in: screen, kind: .screenRecording) == nil)
    }

    @Test func anotherAppOrAnAgentSettingsRowIsNotOurInitialConsent() {
        func item(_ text: String, _ y: CGFloat) -> ScreenText.Item {
            ScreenText.Item(text: text, rect: CGRect(x: 400, y: y, width: 300, height: 20))
        }
        for items in [[item("Zoom would like to control this Mac", 200), item("Open System Settings", 300)],
                      [item("ChatComputerAgent", 200), item("Open System Settings", 300)]] {
            #expect(PermissionGrant.initialConsentButton(in: ScreenText(items: items), kind: .accessibility) == nil)
        }
    }

    @MainActor
    @Test func finishesTheOldControlAlertBeforeRequestingRecording() async throws {
        let image = try pendingControlImage()
        let size = CGSize(width: image.width / 2, height: image.height / 2)
        let screen = try ScreenText.recognize(image, guestSize: size)
        let point = try #require(PermissionGrant.initialConsentButton(in: screen, kind: .accessibility))
        let clear = try probeScreenshot("Finder")
        let source = try #require(CGImageSourceCreateWithData(clear.imageData as CFData, nil))
        let finder = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let display = PendingPermissionDisplay(pendingImage: image, clearedImage: finder, point: point, size: size)
        var recordingRequested = false
        let grant = PermissionGrant(display: display, prepare: { kind in
            #expect(kind == .screenRecording)
            #expect(!display.pending)
            recordingRequested = true
            throw StopAfterRequest.done
        }, isGranted: { $0 == .accessibility }, restartAgent: {}, password: { "unused" },
                                   sleep: { _ in await Task.yield() })
        await #expect(throws: StopAfterRequest.self) { try await grant.run() }
        #expect(recordingRequested)
        #expect(display.clicks == 1)
    }
    @MainActor
    @Test func missingRowDoesNotRepeatedlyRequestOrRestart() async throws {
        let display = EmptyPermissionDisplay()
        var requests = 0
        var settings = 0
        var restarts = 0
        let grant = PermissionGrant(display: display, prepare: { _ in requests += 1 }, isGranted: { _ in false },
                                    restartAgent: { restarts += 1 }, password: { "unused" },
                                    openSettings: { _ in settings += 1 }, sleep: { _ in await Task.yield() })
        await #expect(throws: (any Error).self) { try await grant.grant(.screenRecording) }
        #expect(requests == 1)
        #expect(settings == 1)
        #expect(restarts == 0)
    }
    /// The Accessibility pane on macOS 26.6.2 with the agent listed and off, captured at 2× (part of the screen).
    @Test func findsTheSwitchOnMacOS26() throws {
        let url = try #require(Bundle.module.url(forResource: "accessibility-26", withExtension: "png", subdirectory: "PermissionPanes"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let guestSize = CGSize(width: image.width / 2, height: image.height / 2)
        let screen = try ScreenText.recognize(image, guestSize: guestSize)
        let row = try #require(screen.items.first { $0.text == PermissionGrant.agentName })
        #expect(PermissionGrant.permissionRow(in: screen, kind: .accessibility) == row)
        #expect(PermissionGrant.permissionRow(in: screen, kind: .screenRecording) == nil)

        // The description ends left of the switch: the search must not stop there.
        #expect(PermissionGrant.switchCenter(in: image, guestSize: guestSize, row: row.rect,
                                             rightLimit: PermissionGrant.paneRightEdge(screen, row: row.rect)) == nil)
        let toggle = try #require(PermissionGrant.agentSwitch(in: image, guestSize: guestSize, screen: screen, row: row.rect))
        // The switch spans x 634…671 and sits on the row.
        #expect((634...671).contains(toggle.x))
        #expect(abs(toggle.y - row.rect.midY) < 2)
        #expect(!PermissionGrant.switchIsOn(in: image, guestSize: guestSize, at: toggle))
    }

    @Test func anotherPrivacyPaneCannotTriggerScreenRecordingToggleOrRestart() {
        // The failed 27.0.1 upgrade displayed this Accessibility pane with an
        // enabled agent row while the host was waiting for Screen Recording.
        let row = ScreenText.Item(text: PermissionGrant.agentName, rect: CGRect(x: 562, y: 210, width: 130, height: 15))
        let accessibility = ScreenText.Item(text: "Device Control and Data Access", rect: CGRect(x: 595, y: 80, width: 240, height: 15))
        let sidebar = ScreenText.Item(text: "Screen Recording", rect: CGRect(x: 300, y: 190, width: 140, height: 15))
        let wrong = ScreenText(items: [accessibility, sidebar, row])
        #expect(PermissionGrant.permissionRow(in: wrong, kind: .screenRecording) == nil)
        #expect(PermissionGrant.permissionRow(in: wrong, kind: .accessibility) == row)
        let recording = ScreenText.Item(text: "Screen & System Audio Recording", rect: CGRect(x: 595, y: 80, width: 240, height: 15))
        #expect(PermissionGrant.permissionRow(in: ScreenText(items: [recording, row]), kind: .screenRecording) == row)
    }
}

private enum StopAfterRequest: Error { case done }

/// The next frame is blank during a Settings transition. Coordinates from the
/// first frame must not be used to inspect or act on that second image.
@MainActor
private final class ChangingPermissionDisplay: PermissionDisplay {
    let image: CGImage
    let blank: CGImage
    var captures = 0
    var clicked = false
    var guestSize: CGSize { CGSize(width: image.width / 2, height: image.height / 2) }
    init(image: CGImage) {
        self.image = image
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        blank = context.makeImage()!
    }
    func capture() -> CGImage? { captures += 1; return captures == 1 ? image : blank }
    func click(_ point: CGPoint, count: Int) {
        #expect((940...985).contains(point.x))
        #expect((200...220).contains(point.y))
        #expect(captures == 1)
        clicked = true
    }
    func key(_ combo: String) async throws {}
    func type(_ text: String) async throws {}
}

@MainActor
private final class PendingPermissionDisplay: PermissionDisplay {
    let pendingImage: CGImage
    let clearedImage: CGImage
    let point: CGPoint
    var guestSize: CGSize
    var pending = true
    var clicks = 0
    init(pendingImage: CGImage, clearedImage: CGImage, point: CGPoint, size: CGSize) {
        self.pendingImage = pendingImage; self.clearedImage = clearedImage; self.point = point; self.guestSize = size
    }
    func capture() -> CGImage? { pending ? pendingImage : clearedImage }
    func click(_ point: CGPoint, count: Int) {
        if point == self.point { pending = false; clicks += 1 }
    }
    func key(_ combo: String) async throws {}
    func type(_ text: String) async throws {}
}

@MainActor
private final class EmptyPermissionDisplay: PermissionDisplay {
    var guestSize = CGSize(width: 640, height: 180)
    func capture() -> CGImage? {
        let context = CGContext(data: nil, width: 640, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 180))
        return context.makeImage()
    }
    func click(_ point: CGPoint, count: Int) {}
    func key(_ combo: String) async throws {}
    func type(_ text: String) async throws {}
}
#endif
