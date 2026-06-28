import Foundation

public struct DiagnosticsSecretScanRule: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var pattern: String
    public var caseInsensitive: Bool

    public init(id: String, label: String, pattern: String, caseInsensitive: Bool = false) {
        self.id = id
        self.label = label
        self.pattern = pattern
        self.caseInsensitive = caseInsensitive
    }
}

public struct DiagnosticsSecretScanFinding: Codable, Equatable, Sendable {
    public var ruleID: String
    public var label: String
    public var matchCount: Int

    public init(ruleID: String, label: String, matchCount: Int) {
        self.ruleID = ruleID
        self.label = label
        self.matchCount = matchCount
    }
}

public enum DiagnosticsSecretScanner {
    public static let rules: [DiagnosticsSecretScanRule] = [
        DiagnosticsSecretScanRule(
            id: "private-key",
            label: "private key block",
            pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#
        ),
        DiagnosticsSecretScanRule(
            id: "github-pat",
            label: "GitHub personal access token",
            pattern: #"github_pat_[A-Za-z0-9_]{20,}"#
        ),
        DiagnosticsSecretScanRule(
            id: "github-token",
            label: "GitHub token",
            pattern: #"gh[pousr]_[A-Za-z0-9_]{20,}"#
        ),
        DiagnosticsSecretScanRule(
            id: "openai-token",
            label: "OpenAI-style API token",
            pattern: #"(?:^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_][A-Za-z0-9_-]{19,}"#
        ),
        DiagnosticsSecretScanRule(
            id: "aws-access-key",
            label: "AWS access key ID",
            pattern: #"AKIA[0-9A-Z]{16}"#
        ),
        DiagnosticsSecretScanRule(
            id: "stripe-token",
            label: "Stripe API token",
            pattern: #"[rs]k_(?:live|test)_[A-Za-z0-9]{16,}"#
        ),
        DiagnosticsSecretScanRule(
            id: "bearer-token",
            label: "Bearer token",
            pattern: #"\bBearer\s+[A-Za-z0-9._~+/=-]{24,}"#,
            caseInsensitive: true
        ),
        DiagnosticsSecretScanRule(
            id: "url-userinfo",
            label: "URL credentials",
            pattern: #"https?://[^/\s:@]+(?::[^/\s@]+)?@"#,
            caseInsensitive: true
        ),
    ]

    public static func scan(_ text: String, rules: [DiagnosticsSecretScanRule] = Self.rules) -> [DiagnosticsSecretScanFinding] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return rules.compactMap { rule in
            let options: NSRegularExpression.Options = rule.caseInsensitive ? [.caseInsensitive] : []
            guard let expression = try? NSRegularExpression(pattern: rule.pattern, options: options) else {
                return nil
            }
            let count = expression.numberOfMatches(in: text, options: [], range: fullRange)
            guard count > 0 else { return nil }
            return DiagnosticsSecretScanFinding(ruleID: rule.id, label: rule.label, matchCount: count)
        }
    }
}
