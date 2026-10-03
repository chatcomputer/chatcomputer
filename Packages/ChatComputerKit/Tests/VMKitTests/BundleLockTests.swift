#if os(macOS)
import Foundation
import Testing
@testable import VMKit

@Suite struct BundleLockTests {
    @Test func onlyOneHolderPerBundle() throws {
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory.appendingPathComponent("BundleLockTests-\(UUID().uuidString).vm"))
        try bundle.create()
        #expect(bundle.lock())
        // A second holder (another copy of the app, or cc-harness) is refused.
        #expect(!bundle.lock())
    }
}
#endif
