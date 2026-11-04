#if os(macOS)
import AppKit
import BridgeProtocol
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import HostControl

/// Real pixels exercise PNG decoding and OCR, rather than accepting an API flag.
func probeScreenshot(_ text: String) throws -> Screenshot {
    let context = try #require(CGContext(data: nil, width: 640, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 180))
    let string = NSAttributedString(string: text, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 32, weight: .bold), .foregroundColor: NSColor.black,
    ])
    context.textPosition = CGPoint(x: 35, y: 80)
    CTLineDraw(CTLineCreateWithAttributedString(string), context)
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return Screenshot(imageData: data as Data, mediaType: "image/png", width: 640, height: 180,
                      capturedAt: Date(), observationVersion: 1)
}

@MainActor
@Suite struct CaptureVerificationTests {
    @Test func actualPNGNeedsMatchingWindowAndDimensions() throws {
        let shot = try probeScreenshot("CC CAPTURE 123456")
        try GuestCaptureVerifier.validatePixels(shot, marker: "CC CAPTURE 123456")
        #expect(throws: (any Error).self) { try GuestCaptureVerifier.validatePixels(shot, marker: "CC CAPTURE 654321") }
        let blank = try probeScreenshot("")
        #expect(throws: (any Error).self) { try GuestCaptureVerifier.validatePixels(blank, marker: "CC CAPTURE 123456") }
        var wrongSize = shot
        wrongSize.width += 1
        #expect(throws: (any Error).self) { try GuestCaptureVerifier.validatePixels(wrongSize, marker: "CC CAPTURE 123456") }
        var corrupt = shot
        corrupt.imageData = Data("not a PNG".utf8)
        #expect(throws: (any Error).self) { try GuestCaptureVerifier.validatePixels(corrupt, marker: "CC CAPTURE 123456") }
    }

    @Test func twoRealCapturesAndProbeCleanupAreRequired() async throws {
        var marker = ""
        var captures = 0
        var hidden = false
        let verifier = GuestCaptureVerifier(showProbe: { value in
            if let value { marker = value } else { hidden = true }
        }, capture: {
            captures += 1
            return try probeScreenshot(marker)
        }, handlePrompt: { false }, sleep: { _ in await Task.yield() })
        try await verifier.run()
        #expect(captures == 2)
        #expect(hidden)
    }

    @Test func secondCaptureFailureCannotPassAndCleansProbe() async throws {
        var captures = 0
        var hidden = false
        let verifier = GuestCaptureVerifier(showProbe: { if $0 == nil { hidden = true } }, capture: {
            captures += 1
            if captures == 2 { throw HostControlError.noFramebuffer }
            return try probeScreenshot("placeholder")
        }, handlePrompt: { false }, validate: { _, _ in }, sleep: { _ in await Task.yield() })
        await #expect(throws: (any Error).self) { try await verifier.run() }
        #expect(hidden)
        #expect(captures == 2)
    }

    @Test func anOldFirstFrameMustBeFollowedByTwoMatchingFrames() async throws {
        var marker = ""
        var captures = 0
        var hidden = false
        let verifier = GuestCaptureVerifier(showProbe: {
            if let value = $0 { marker = value } else { hidden = true }
        }, capture: {
            captures += 1
            return try probeScreenshot(captures == 1 ? "previous desktop" : marker)
        }, handlePrompt: { false }, sleep: { _ in await Task.yield() })
        try await verifier.run()
        #expect(captures == 3)
        #expect(hidden)
    }

    @Test func aNonmatchingFrameResetsTheConsecutivePixelCount() async throws {
        var marker = ""
        var captures = 0
        let verifier = GuestCaptureVerifier(showProbe: { if let value = $0 { marker = value } }, capture: {
            captures += 1
            return try probeScreenshot(captures == 2 ? "previous desktop" : marker)
        }, handlePrompt: { false }, sleep: { _ in await Task.yield() })
        try await verifier.run()
        #expect(captures == 4)
    }

    @Test func intermittentMatchesCannotPassAndRetriesAreBounded() async throws {
        var marker = ""
        var captures = 0
        var hidden = false
        let verifier = GuestCaptureVerifier(showProbe: {
            if let value = $0 { marker = value } else { hidden = true }
        }, capture: {
            captures += 1
            return try probeScreenshot(captures.isMultiple(of: 2) ? "previous desktop" : marker)
        }, handlePrompt: { false }, sleep: { _ in await Task.yield() })
        await #expect(throws: (any Error).self) { try await verifier.run() }
        #expect(captures == 4)
        #expect(hidden)
    }

    @Test func hostAnswersConsentWhileCaptureIsWaiting() async throws {
        var waiting = false
        var allowed = false
        var captures = 0
        let verifier = GuestCaptureVerifier(showProbe: { _ in }, capture: {
            captures += 1
            if captures == 1 {
                waiting = true
                while !allowed { await Task.yield() }
            }
            return try probeScreenshot("placeholder")
        }, handlePrompt: {
            if waiting, !allowed { allowed = true; return true }
            return false
        }, validate: { _, _ in }, sleep: { _ in await Task.yield() })
        try await verifier.run()
        #expect(allowed)
        #expect(captures == 3) // consent capture + two prompt-free captures
    }

    @Test func recurringConsentNeverCountsAsReady() async throws {
        var captures = 0
        let verifier = GuestCaptureVerifier(showProbe: { _ in }, capture: {
            captures += 1
            return try probeScreenshot("placeholder")
        },
                                             handlePrompt: { true }, validate: { _, _ in }, sleep: { _ in await Task.yield() })
        await #expect(throws: (any Error).self) { try await verifier.run() }
        #expect(captures == 5) // the first consent renews the budget once, never indefinitely
    }

    @Test func lateConsentRequiresANewMarkerAndTwoFreshFrames() async throws {
        var marker = ""
        var markers: [String] = []
        var captures = 0
        var answered = false
        var hidden = false
        let verifier = GuestCaptureVerifier(showProbe: { value in
            if let value { marker = value; markers.append(value) } else { hidden = true }
        }, capture: {
            captures += 1
            // A good frame precedes the system modal. Its old pixels arrive
            // once more after Allow and must not count toward readiness.
            return try probeScreenshot(captures == 3 ? markers[0] : marker)
        }, handlePrompt: {
            if captures == 2, !answered { answered = true; return true }
            return false
        }, sleep: { _ in await Task.yield() })
        try await verifier.run()
        #expect(markers.count == 2)
        #expect(markers[0] != markers[1])
        #expect(captures == 5)
        #expect(hidden)
    }

    @Test func consentDuringAFailedCaptureRenewsTheProbeBeforeRetry() async throws {
        var marker = ""
        var markers: [String] = []
        var captures = 0
        var waiting = false
        var answered = false
        let verifier = GuestCaptureVerifier(showProbe: { value in
            if let value { marker = value; markers.append(value) }
        }, capture: {
            captures += 1
            if captures == 1 { waiting = true; throw HostControlError.noFramebuffer }
            return try probeScreenshot(marker)
        }, handlePrompt: {
            if waiting, !answered { answered = true; return true }
            return false
        }, sleep: { _ in await Task.yield() })
        try await verifier.run()
        #expect(markers.count == 2)
        #expect(markers[0] != markers[1])
        #expect(captures == 3)
    }

    @Test func cancellationCleansProbe() async throws {
        var hidden = false
        let verifier = GuestCaptureVerifier(showProbe: { if $0 == nil { hidden = true } }, capture: {
            throw CancellationError()
        }, handlePrompt: { false }, sleep: { _ in await Task.yield() })
        await #expect(throws: CancellationError.self) { try await verifier.run() }
        #expect(hidden)
    }

    @Test func cancellationStopsObservingEvenWhenTheCaptureRPCIsStillWaiting() async throws {
        var captureEntered = false
        var releaseCapture = false
        var observations = 0
        var hidden = false
        let verifier = GuestCaptureVerifier(showProbe: { if $0 == nil { hidden = true } }, capture: {
            captureEntered = true
            while !releaseCapture { await Task.yield() }
            return try probeScreenshot("placeholder")
        }, handlePrompt: { observations += 1; return false }, validate: { _, _ in },
                                             sleep: { _ in await Task.yield() })
        let work = Task { try await verifier.run() }
        while !captureEntered { await Task.yield() }
        work.cancel()
        for _ in 0..<20 { await Task.yield() }
        let stoppedAt = observations
        for _ in 0..<20 { await Task.yield() }
        #expect(observations == stoppedAt)
        releaseCapture = true
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(hidden)
    }

    @Test func probeCleanupAlsoRunsWhenShowingItFails() async throws {
        var hidden = false
        let verifier = GuestCaptureVerifier(showProbe: { marker in
            if marker != nil { throw HostControlError.noWindow }
            hidden = true
        }, capture: { try probeScreenshot("unused") }, handlePrompt: { false })
        await #expect(throws: (any Error).self) { try await verifier.run() }
        #expect(hidden)
    }

    @Test func journalSurvivesRestartAndDoesNotContainCapturePixels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PermissionJournal(directory: directory)
        try journal.append(stage: "capture-agent-not-connected", appVersion: "0.9.12 (44)")
        try PermissionJournal(directory: directory).append(stage: "capture-verification-failed", appVersion: "0.9.12 (44)")
        let data = try Data(contentsOf: journal.url)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(!String(decoding: data, as: UTF8.self).contains("imageData"))
        let attributes = try FileManager.default.attributesOfItem(atPath: journal.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
#endif
