import Foundation

public struct DiagnosticsRedactor: Sendable {
    public static let rulesVersion = 1

    public init() {}

    public func redact(_ bundle: DiagnosticsBundle) -> RedactedDiagnosticsBundle {
        var state = RedactionState()
        var redacted = bundle

        redacted.note = redacted.note.map { state.redactFreeformText($0) }
        redacted.app = state.redactApp(redacted.app)
        redacted.logs = state.redactLogs(redacted.logs)
        redacted.shell = state.redactShell(redacted.shell)
        redacted.socket = state.redactSocket(redacted.socket)
        redacted.automation = redacted.automation.map { state.redactAutomation($0) }
        redacted.probe = state.redactProbe(redacted.probe)
        redacted.redaction = DiagnosticsRedactionSection(
            rulesVersion: Self.rulesVersion,
            redactedKeyCount: state.redactionCount
        )

        return RedactedDiagnosticsBundle(bundle: redacted)
    }
}

private struct RedactionState {
    private static let redactedSecret = "<redacted:secret>"
    private static let redactedToken = "<redacted:token>"
    private static let redactedPrivateKey = "<redacted:private-key>"
    private static let redactedURLUserInfo = "<redacted:userinfo>"

    private static let environmentValueWhitelist: Set<String> = [
        "PATH",
        "SHELL",
        "TERM",
        "TERM_PROGRAM",
    ]

    var redactionCount = 0

    mutating func redactApp(_ app: DiagnosticsAppSection) -> DiagnosticsAppSection {
        var app = app
        app.instanceStatus = redactAvailability(app.instanceStatus)
        app.infoPlistStatus = redactAvailability(app.infoPlistStatus)
        return app
    }

    mutating func redactLogs(_ logs: DiagnosticsLogsSection) -> DiagnosticsLogsSection {
        var logs = logs
        logs.current.content = logs.current.content.map { redactFreeformText($0) }
        logs.current.readError = logs.current.readError.map { redactFreeformText($0) }
        logs.previous.content = logs.previous.content.map { redactFreeformText($0) }
        logs.previous.readError = logs.previous.readError.map { redactFreeformText($0) }
        logs.configSummary = redactDictionary(logs.configSummary)
        return logs
    }

    mutating func redactShell(_ shell: DiagnosticsShellSection) -> DiagnosticsShellSection {
        var shell = shell
        shell.detectedShells = shell.detectedShells.map { initFile in
            var initFile = initFile
            initFile.readError = initFile.readError.map { redactFreeformText($0) }
            return initFile
        }
        shell.shimDirectory.readError = shell.shimDirectory.readError.map { redactFreeformText($0) }
        shell.environment = shell.environment.map { entry in
            DiagnosticsEnvironmentEntry(
                name: entry.name,
                value: entry.value.map { redactEnvironmentValue($0, key: entry.name) }
            )
        }
        return shell
    }

    mutating func redactSocket(_ socket: DiagnosticsSocketProbeResult) -> DiagnosticsSocketProbeResult {
        var socket = socket
        socket.stat.error = socket.stat.error.map { redactFreeformText($0) }
        socket.connect.error = socket.connect.error.map { redactFreeformText($0) }
        if var ping = socket.ping {
            ping.error = ping.error.map { redactFreeformText($0) }
            socket.ping = ping
        }
        if var currentSocketRecord = socket.currentSocketRecord {
            currentSocketRecord.readError = currentSocketRecord.readError.map { redactFreeformText($0) }
            socket.currentSocketRecord = currentSocketRecord
        }
        return socket
    }

    mutating func redactAutomation(_ automation: DiagnosticsAutomationSection) -> DiagnosticsAutomationSection {
        var automation = automation
        automation.status = redactAvailability(automation.status)
        return automation
    }

    mutating func redactProbe(_ probe: DiagnosticsProbeSection) -> DiagnosticsProbeSection {
        var probe = probe
        probe.rawShellProbe = probe.rawShellProbe.map { redactFreeformText($0) }
        probe.readError = probe.readError.map { redactFreeformText($0) }
        return probe
    }

    private mutating func redactAvailability(_ availability: DiagnosticsAvailability) -> DiagnosticsAvailability {
        DiagnosticsAvailability(
            status: availability.status,
            detail: availability.detail.map { redactFreeformText($0) }
        )
    }

    private mutating func redactDictionary(_ dictionary: [String: String]) -> [String: String] {
        dictionary.reduce(into: [:]) { partialResult, element in
            if Self.isSensitiveKey(element.key) {
                partialResult[element.key] = redactWholeValue()
            } else {
                partialResult[element.key] = redactFreeformText(element.value)
            }
        }
    }

    private mutating func redactEnvironmentValue(_ value: String, key: String) -> String {
        if Self.isSensitiveKey(key) {
            return redactWholeValue()
        }

        if key.hasPrefix("TOASTTY_") || Self.environmentValueWhitelist.contains(key) {
            return redactFreeformText(value)
        }

        return redactWholeValue()
    }

    mutating func redactFreeformText(_ value: String) -> String {
        var result = value
        result = replaceMatches(
            in: result,
            pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
            replacement: Self.redactedPrivateKey
        )
        result = replaceURLCredentials(in: result)
        result = replaceMatches(
            in: result,
            pattern: #"github_pat_[A-Za-z0-9_]{20,}"#,
            replacement: Self.redactedToken
        )
        result = replaceMatches(
            in: result,
            pattern: #"gh[pousr]_[A-Za-z0-9_]{20,}"#,
            replacement: Self.redactedToken
        )
        result = replaceMatches(
            in: result,
            pattern: #"sk-[A-Za-z0-9_-]{20,}"#,
            replacement: Self.redactedToken
        )
        result = replaceMatches(
            in: result,
            pattern: #"AKIA[0-9A-Z]{16}"#,
            replacement: "<redacted:aws-access-key>"
        )
        result = replaceMatches(
            in: result,
            pattern: #"[rs]k_(?:live|test)_[A-Za-z0-9]{16,}"#,
            replacement: Self.redactedToken
        )
        result = replaceBearerTokens(in: result)
        result = replaceQuotedSensitiveAssignments(in: result)
        result = replaceSensitiveAssignments(in: result)
        return result
    }

    private mutating func redactWholeValue() -> String {
        redactionCount += 1
        return Self.redactedSecret
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        let tokens = lowercased
            .split { character in
                character.isLetter || character.isNumber ? false : true
            }
            .map(String.init)
        let sensitiveTokens: Set<String> = [
            "key",
            "token",
            "secret",
            "password",
            "passphrase",
            "credential",
            "credentials",
            "auth",
            "authorization",
            "cookie",
            "session",
        ]
        if tokens.contains(where: sensitiveTokens.contains) {
            return true
        }

        if lowercased.hasSuffix("_session_secret") {
            return true
        }

        return false
    }

    private mutating func replaceQuotedSensitiveAssignments(in value: String) -> String {
        replaceMatches(
            in: value,
            pattern: #"(?i)(["']?\b([A-Z0-9_]+)\b["']?\s*[:=]\s*)(["'])([^"'\r\n]*)(\3)"#,
            replacement: { match, source in
                guard let prefixRange = Range(match.range(at: 1), in: source),
                      let keyRange = Range(match.range(at: 2), in: source),
                      let quoteRange = Range(match.range(at: 3), in: source),
                      Self.isSensitiveKey(String(source[keyRange])) else {
                    guard let matchRange = Range(match.range, in: source) else {
                        return ""
                    }
                    return String(source[matchRange])
                }
                let quote = String(source[quoteRange])
                return String(source[prefixRange]) + quote + Self.redactedSecret + quote
            }
        )
    }

    private mutating func replaceSensitiveAssignments(in value: String) -> String {
        replaceMatches(
            in: value,
            pattern: #"(?i)(["']?\b([A-Z0-9_]+)\b["']?\s*[:=]\s*["']?)([^"'\s,;\]\}]+)"#,
            replacement: { match, source in
                guard let prefixRange = Range(match.range(at: 1), in: source),
                      let keyRange = Range(match.range(at: 2), in: source),
                      Self.isSensitiveKey(String(source[keyRange])) else {
                    guard let matchRange = Range(match.range, in: source) else {
                        return ""
                    }
                    return String(source[matchRange])
                }
                return String(source[prefixRange]) + Self.redactedSecret
            }
        )
    }

    private mutating func replaceBearerTokens(in value: String) -> String {
        replaceMatches(
            in: value,
            pattern: #"(?i)\b(Bearer\s+)([A-Za-z0-9._~+/=-]{12,})"#,
            replacement: { match, source in
                guard let prefixRange = Range(match.range(at: 1), in: source) else {
                    return Self.redactedToken
                }
                return String(source[prefixRange]) + Self.redactedToken
            }
        )
    }

    private mutating func replaceURLCredentials(in value: String) -> String {
        replaceMatches(
            in: value,
            pattern: #"(?i)\b(https?://)([^/\s:@]+(?::[^/\s@]+)?@)"#,
            replacement: { match, source in
                guard let schemeRange = Range(match.range(at: 1), in: source) else {
                    return Self.redactedURLUserInfo
                }
                return String(source[schemeRange]) + Self.redactedURLUserInfo + "@"
            }
        )
    }

    private mutating func replaceMatches(
        in value: String,
        pattern: String,
        replacement: String
    ) -> String {
        replaceMatches(in: value, pattern: pattern) { _, _ in replacement }
    }

    private mutating func replaceMatches(
        in value: String,
        pattern: String,
        replacement: (NSTextCheckingResult, String) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else {
            return value
        }

        var result = value
        let source = value
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = expression.matches(in: source, options: [], range: range)
        guard matches.isEmpty == false else {
            return value
        }

        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else {
                continue
            }
            let original = String(result[matchRange])
            let redacted = replacement(match, source)
            guard redacted != original else {
                continue
            }
            result.replaceSubrange(matchRange, with: redacted)
            redactionCount += 1
        }
        return result
    }
}
