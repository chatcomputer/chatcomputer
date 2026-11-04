#if os(macOS)
import BridgeProtocol
import Foundation
import ImageIO

/// Checks pixels from the guest agent while the host remains able to answer the
/// agent's screen-capture consent dialog. Neither health flags nor blank PNGs pass.
@MainActor
public struct GuestCaptureVerifier {
    private enum PixelCheckError: Error, LocalizedError {
        case probeNotVisible

        var errorDescription: String? {
            "The screenshot did not show the capture-check window. Finish any pending Screen Recording prompt and retry."
        }
    }

    public var showProbe: (String?) async throws -> Void
    public var capture: () async throws -> Screenshot
    public var handlePrompt: () async throws -> Bool
    public var validate: (Screenshot, String) throws -> Void
    public var sleep: (Duration) async throws -> Void
    public var log: (String) -> Void

    public init(showProbe: @escaping (String?) async throws -> Void,
                capture: @escaping () async throws -> Screenshot,
                handlePrompt: @escaping () async throws -> Bool,
                validate: @escaping (Screenshot, String) throws -> Void = GuestCaptureVerifier.validatePixels,
                sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                log: @escaping (String) -> Void = { _ in }) {
        self.showProbe = showProbe
        self.capture = capture
        self.handlePrompt = handlePrompt
        self.validate = validate
        self.sleep = sleep
        self.log = log
    }

    public func run() async throws {
        var marker = "CC CAPTURE \(Int.random(in: 100_000...999_999))"
        try Task.checkCancellation()
        do {
            try await showProbe(marker)
            try await sleep(.seconds(1))
            var consecutive = 0
            var remainingAttempts = 4
            var renewedAfterConsent = false
            func renewProbeAfterConsent() async throws {
                // A system modal can change the window ordering after an earlier
                // good frame. Re-present a fresh marker so pre-consent pixels
                // cannot establish readiness after the dialog is answered.
                let oldMarker = marker
                repeat { marker = "CC CAPTURE \(Int.random(in: 100_000...999_999))" } while marker == oldMarker
                try await showProbe(marker)
                if !renewedAfterConsent {
                    remainingAttempts = 4
                    renewedAfterConsent = true
                }
                log("capture-probe-renewed-after-consent")
            }
            while remainingAttempts > 0 {
                remainingAttempts -= 1
                try Task.checkCancellation()
                var answeredPrompt = false
                // The screenshot RPC can wait on a system dialog. A separate host
                // task observes the framebuffer until that RPC completes.
                let pump = Task {
                    while !Task.isCancelled {
                        if try await handlePrompt() { answeredPrompt = true }
                        try await sleep(.milliseconds(250))
                    }
                }
                let shot: Screenshot
                do {
                    shot = try await withTaskCancellationHandler {
                        try await capture()
                    } onCancel: {
                        pump.cancel()
                    }
                }
                catch {
                    pump.cancel()
                    _ = try? await pump.value
                    try Task.checkCancellation()
                    if try await handlePrompt() { answeredPrompt = true }
                    if answeredPrompt {
                        consecutive = 0
                        log("capture-consent-answered")
                        try await renewProbeAfterConsent()
                        try await sleep(.seconds(1))
                        continue
                    }
                    throw error
                }
                pump.cancel()
                // Await the pump so a late OCR result cannot click after success.
                _ = try? await pump.value
                try Task.checkCancellation()
                if try await handlePrompt() { answeredPrompt = true }
                if !answeredPrompt {
                    do { try validate(shot, marker) }
                    catch PixelCheckError.probeNotVisible {
                        // A decodable frame can precede the newly shown window.
                        // It never counts toward the two consecutive checks.
                        consecutive = 0
                        log("capture-probe-not-yet-visible")
                        if remainingAttempts == 0 { throw PixelCheckError.probeNotVisible }
                        try await sleep(.seconds(1))
                        continue
                    }
                }
                consecutive = answeredPrompt ? 0 : consecutive + 1
                log(answeredPrompt ? "capture-consent-answered" : "capture-pixels-verified-\(consecutive)")
                if answeredPrompt { try await renewProbeAfterConsent() }
                if consecutive == 2 {
                    try await showProbe(nil)
                    return
                }
                try await sleep(.seconds(1))
            }
            throw HostControlError.gaveUp("The guest did not provide two consecutive captures of the capture-check window. Finish any pending Screen Recording prompt and retry.")
        } catch {
            try? await showProbe(nil)
            throw error
        }
    }

    nonisolated public static func validatePixels(_ shot: Screenshot, marker: String) throws {
        guard shot.width > 0, shot.height > 0,
              let source = CGImageSourceCreateWithData(shot.imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == shot.width, image.height == shot.height else {
            throw HostControlError.gaveUp("The guest returned an invalid screenshot. Check Screen Recording permission and retry.")
        }
        let text = try ScreenText.recognize(image, guestSize: CGSize(width: image.width, height: image.height))
        let normalized = text.items.map(\.text).joined().filter { $0.isLetter || $0.isNumber }.uppercased()
        guard normalized.contains(marker.filter { $0.isLetter || $0.isNumber }.uppercased()) else {
            throw PixelCheckError.probeNotVisible
        }
    }
}
#endif
