import Testing
@testable import ChatCore

@Suite struct RedactorTests {
    @Test func removesKnownSecretsAndKeyShapedText() {
        let redactor = Redactor(secrets: ["hunter2-guest", "abc"])
        let text = """
            password hunter2-guest typed; short abc stays
            401: invalid key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWX
            google AIzaSyA1234567890abcdefghijklmnopqrstu
            Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345
            "apiKey": "0123456789abcdef0123"
            """
        let clean = redactor.redact(text)
        #expect(!clean.contains("hunter2-guest"))
        #expect(clean.contains("short abc stays"))
        #expect(!clean.contains("sk-ant-api03"))
        #expect(!clean.contains("AIzaSy"))
        #expect(!clean.contains("abcdefghijklmnopqrstuvwxyz012345"))
        #expect(!clean.contains("0123456789abcdef0123"))
        #expect(clean.contains("401: invalid key [redacted]"))
    }

    @Test func leavesOrdinaryTextAlone() {
        let text = "Saved note.txt to the outbox after 12 turns; task-ID 3f2a, skipped 2 steps."
        #expect(Redactor(secrets: []).redact(text) == text)
    }
}
