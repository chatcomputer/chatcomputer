#if os(macOS)
import CoreGraphics
import Foundation
import Testing
@testable import HostControl

/// Text recognized on the real Setup Assistant of macOS 26.6.2 (25G83), one fixture per screen, in the order a
/// fresh guest shows them.
@Suite struct SetupAssistantTests {
    static func screen(_ name: String) throws -> ScreenText {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "SetupAssistantScreens"))
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        return ScreenText(items: raw.map { item in
            ScreenText.Item(text: item["text"] as? String ?? "",
                            rect: CGRect(x: item["x"] as? Int ?? 0, y: item["y"] as? Int ?? 0, width: item["w"] as? Int ?? 0, height: item["h"] as? Int ?? 0))
        })
    }

    @Test(arguments: [
        ("shot-001", "hello"),
        ("shot-002", "language"),
        ("shot-004", "country"),
        ("shot-005", "country"),
        ("shot-006", "transfer"),
        ("shot-007", "languages"),
        ("shot-008", "accessibility"),
        ("shot-009", "data & privacy"),
        ("shot-010", "account"),
        ("shot-013", "apple account"),
        ("shot-014", "apple account"),
        ("shot-015", "skip apple account?"),
        ("shot-016", "terms"),
        ("shot-017", "agree dialog"),
        ("shot-018", "age"),
        ("shot-019", "location"),
        ("shot-020", "location dialog"),
        ("shot-021", "time zone"),
        ("shot-022", "analytics"),
        ("shot-023", "screen time"),
        ("shot-024", "filevault"),
        ("shot-025", "filevault dialog"),
        ("shot-026", "look"),
        ("shot-027", "updates"),
        ("shot-028", "welcome"),
        ("shot-029", "desktop"),
    ])
    func recognizesEveryPage(fixture: String, page: String) throws {
        #expect(SetupAssistant.page(try Self.screen(fixture)) == page)
    }

    @Test func theAccountPageHasItsFields() throws {
        let screen = try Self.screen("shot-010")
        for label in ["Full Name", "Account Name", "Password", "Verify Password", "Allow computer account password", "Continue"] {
            #expect(screen.first(label) != nil, "missing \(label)")
        }
    }
}
#endif
