#if os(macOS)
import CoreGraphics
import Foundation
import Vision

/// On-device text recognition over a guest screenshot (Vision framework; nothing leaves the Mac).
public struct ScreenText: Sendable {
    public struct Item: Sendable, Equatable {
        public var text: String
        /// Guest points, top-left origin.
        public var rect: CGRect
        public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    public static func recognize(_ image: CGImage, guestSize: CGSize) throws -> ScreenText {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let items: [Item] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision boxes are normalized with a bottom-left origin.
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * guestSize.width, y: (1 - box.maxY) * guestSize.height,
                              width: box.width * guestSize.width, height: box.height * guestSize.height)
            return Item(text: candidate.string, rect: rect)
        }
        return ScreenText(items: items)
    }

    /// The first item whose text contains `needle` (case-insensitive), preferring exact matches.
    public func first(_ needle: String) -> Item? {
        let lowered = needle.lowercased()
        return items.first { $0.text.lowercased() == lowered }
            ?? items.first { $0.text.lowercased().contains(lowered) }
    }

    public func contains(_ needle: String) -> Bool { first(needle) != nil }
}
#endif
