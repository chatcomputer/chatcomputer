import Foundation

/// Removes secrets from text that leaves the Mac, such as a diagnostics archive. The known secrets (API keys, the
/// guest password, the pairing token) are replaced wherever they appear; anything shaped like an API key or a
/// bearer token is replaced too, in case a provider echoed a key in an error message.
public struct Redactor: Sendable {
    public static let placeholder = "[redacted]"

    private let known: [String]

    /// Secrets shorter than 4 characters are ignored: replacing them would mangle ordinary text.
    public init(secrets: [String]) {
        known = secrets.filter { $0.count >= 4 }.sorted { $0.count > $1.count }
    }

    private static let patterns: [NSRegularExpression] = [
        #"sk-[A-Za-z0-9_\-]{16,}"#,                 // OpenAI, Anthropic, DeepSeek and most compatible providers
        #"AIza[0-9A-Za-z_\-]{30,}"#,                // Google
        #"xai-[A-Za-z0-9]{20,}"#,                   // xAI
        #"(?i)(bearer|x-api-key:?|api[_-]?key["':= ]+)\s*[A-Za-z0-9._\-]{16,}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public func redact(_ text: String) -> String {
        var result = text
        for secret in known { result = result.replacingOccurrences(of: secret, with: Self.placeholder) }
        for pattern in Self.patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: Self.placeholder)
        }
        return result
    }
}
