import Foundation

enum CodexSkillsContract {
    static let pluginName = "toastty"
    static let marketplaceName = "toastty"
    static let retiredQualifiedSkillNames = ["toastty:worktree-done"]
}

struct CodexSkillsLaunchConfiguration: Equatable, Sendable {
    let qualifiedSkillNames: [String]
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

enum CodexSkillsConfigSerializer {
    static func skillsConfigOverride(enabling skillNames: [String]) -> String {
        let entries = Set(skillNames).sorted().map { name in
            "{name=\(tomlBasicStringLiteral(name)),enabled=true}"
        }
        return "skills.config=[\(entries.joined(separator: ","))]"
    }

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
