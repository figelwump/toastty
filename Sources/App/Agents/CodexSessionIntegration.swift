import Foundation

enum CodexSkillsContract {
    static let pluginName = "toastty"
    static let marketplaceName = "toastty"
    static let pluginSelector = "\(pluginName)@\(marketplaceName)"
    /// Profile overlay name injected as `--profile toastty-managed` on managed
    /// runtime commands. The matching overlay file lives at
    /// `$CODEX_HOME/toastty-managed.config.toml`.
    static let profileName = "toastty-managed"
    static let profileConfigFileName = "\(profileName).config.toml"
}

/// The Toastty-owned Codex profile overlay file. It contains only the plugin
/// enablement for the shipped skills plugin; combined with the populated
/// plugin cache and the injected `--profile` flag it activates the skills for
/// exactly the flagged managed process (see
/// docs/plans/evidence/codex-session-scoped-skills-2026-08-04.md).
enum CodexManagedProfileConfig {
    /// First line of every Toastty-written overlay. A file at the profile path
    /// without this marker is foreign and must never be overwritten.
    static let ownershipMarker = "# managed by Toastty — do not edit; safe to delete"

    static var fileContents: String {
        """
        \(ownershipMarker)
        [plugins."\(CodexSkillsContract.pluginSelector)"]
        enabled = true

        """
    }

    static func isToasttyOwned(_ contents: String) -> Bool {
        contents.contains(ownershipMarker)
    }
}

struct CodexSkillsLaunchConfiguration: Equatable, Sendable {
    let profileName: String
    let codexHomePath: String
    let skillsRootPath: String
    let version: String
    let contentDigest: String
}

enum CodexSkillsInjectionResult: Equatable, Sendable {
    case notRequested
    case injected
    case refused(reason: String)

    var wasRefused: Bool {
        if case .refused = self { return true }
        return false
    }
}

enum CodexConfigTOMLSerializer {
    static func tomlStringArrayLiteral(_ values: [String]) -> String {
        "[\(values.map(tomlBasicStringLiteral(_:)).joined(separator: ","))]"
    }

    static func tomlBasicStringLiteral(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped.append("\\\\")
            case "\"": escaped.append("\\\"")
            case "\n": escaped.append("\\n")
            case "\r": escaped.append("\\r")
            case "\t": escaped.append("\\t")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped.append(String(format: "\\u%04x", Int(scalar.value)))
                } else {
                    escaped.append(String(scalar))
                }
            }
        }
        return "\"\(escaped)\""
    }
}
