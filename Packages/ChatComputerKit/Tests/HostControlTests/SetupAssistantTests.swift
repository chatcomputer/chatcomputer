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

    @Test func recognizesAnExistingAccountsLoginAfterRestart() {
        let screen = ScreenText(items: [
            .init(text: "Enter Password", rect: CGRect(x: 500, y: 690, width: 180, height: 24)),
            .init(text: "Your password is required to", rect: CGRect(x: 500, y: 730, width: 240, height: 20)),
            .init(text: "log in", rect: CGRect(x: 590, y: 752, width: 60, height: 20)),
        ])
        #expect(SetupAssistant.page(screen) == "login")
    }

    @Test func recognizesTheSavedAccountsRealLockScreen() throws {
        let screen = try Self.screen("lock-26")
        #expect(SetupAssistant.page(screen, fullName: "Chat Computer") == "login")
        #expect(SetupAssistant.page(screen, fullName: "Another account") != "login")
        #expect(SetupAssistant.page(screen) != "login")
    }

    @Test func accountCreationIsNotAnExistingAccountLogin() throws {
        let original = try Self.screen("shot-010")
        let screen = ScreenText(items: original.items + [
            .init(text: "Chat Computer", rect: .zero),
            .init(text: "Enter Password", rect: .zero),
        ])
        #expect(SetupAssistant.page(screen, fullName: "Chat Computer") == "account")
    }

    @Test func aRestoredTerminalIsAnUnlockedDesktop() throws {
        let screen = try Self.screen("terminal-restored-26")
        #expect(TerminalBootstrap.isTerminal(screen))
        #expect(SetupAssistant.page(screen, fullName: "Chat Computer") == "desktop")
    }

    @Test func recognizesRealMergedTerminalMenuTitles() throws {
        let screen = try Self.screen("terminal-menu-merged-26")
        #expect(TerminalBootstrap.isTerminal(screen))
        #expect(SetupAssistant.page(screen, fullName: "Chat Computer") == "desktop")
    }

    @Test func terminalIdentityNeedsBothWholeMenuWords() {
        let body = ScreenText(items: [.init(text: "Terminal Shell", rect: CGRect(x: 20, y: 100, width: 200, height: 20))])
        #expect(!TerminalBootstrap.isTerminal(body))
        let another = ScreenText(items: [.init(text: "FakeTerminal Shell", rect: CGRect(x: 20, y: 4, width: 200, height: 20))])
        #expect(!TerminalBootstrap.isTerminal(another))
    }
}
#endif
