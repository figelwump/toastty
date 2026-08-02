import Foundation

enum CodexSessionIntegrationContract {
    static let pluginName = "toastty"
    static let marketplaceName = "toastty"
    static let hookStatusMessage = "Toastty Agent Status"
    static let hookTimeoutSeconds = 5

    static let hookDefinitions: [CodexSessionHookDefinition] = [
        CodexSessionHookDefinition(event: .sessionStart),
        CodexSessionHookDefinition(event: .userPromptSubmit),
        CodexSessionHookDefinition(event: .permissionRequest, matcher: "*"),
        CodexSessionHookDefinition(event: .preToolUse, matcher: "*"),
        CodexSessionHookDefinition(event: .subagentStart),
        CodexSessionHookDefinition(event: .subagentStop),
        CodexSessionHookDefinition(event: .stop),
    ]

    static func launchOverrides(
        enabling skillNames: [String],
        forwarderCommand: String
    ) -> [String] {
        [
            CodexSessionConfigSerializer.skillsConfigOverride(enabling: skillNames),
            CodexSessionConfigSerializer.hooksOverride(
                definitions: hookDefinitions,
                command: forwarderCommand,
                timeoutSeconds: hookTimeoutSeconds,
                statusMessage: hookStatusMessage
            ),
        ]
    }
}

enum CodexSessionHookEvent: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case permissionRequest = "PermissionRequest"
    case preToolUse = "PreToolUse"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"

    init?(listValue: String) {
        switch listValue {
        case "sessionStart": self = .sessionStart
        case "userPromptSubmit": self = .userPromptSubmit
        case "permissionRequest": self = .permissionRequest
        case "preToolUse": self = .preToolUse
        case "subagentStart": self = .subagentStart
        case "subagentStop": self = .subagentStop
        case "stop": self = .stop
        default: return nil
        }
    }
}

struct CodexSessionHookDefinition: Codable, Equatable, Hashable, Sendable {
    let event: CodexSessionHookEvent
    let matcher: String?

    init(event: CodexSessionHookEvent, matcher: String? = nil) {
        self.event = event
        self.matcher = matcher
    }
}

enum CodexHookTrustState: String, Codable, Equatable, Sendable {
    case trusted
    case managed
    case untrusted
    case changed
    case unknown

    init(listValue: String) {
        switch listValue {
        case "trusted": self = .trusted
        case "managed": self = .managed
        case "untrusted": self = .untrusted
        case "modified": self = .changed
        default: self = .unknown
        }
    }
}

enum CodexSessionIntegrationSupport: String, Codable, Equatable, Sendable {
    case supported
    case unsupported
    case unavailable
}

struct CodexSessionHookAssessment: Codable, Equatable, Sendable {
    let event: CodexSessionHookEvent
    let trust: CodexHookTrustState
    let definitionHash: String?
    let definitionMatchesExpected: Bool

    init(
        event: CodexSessionHookEvent,
        trust: CodexHookTrustState,
        definitionHash: String?,
        definitionMatchesExpected: Bool = true
    ) {
        self.event = event
        self.trust = trust
        self.definitionHash = definitionHash
        self.definitionMatchesExpected = definitionMatchesExpected
    }
}

struct CodexSessionIntegrationAssessment: Codable, Equatable, Sendable {
    let support: CodexSessionIntegrationSupport
    let expectedSkillNames: [String]
    let installedSkillNames: [String]
    let enabledSkillNames: [String]
    let sessionHooks: [CodexSessionHookAssessment]
    let legacyGlobalHooksPresent: Bool
    let warnings: [String]
    let errors: [String]

    var hasExactPluginSkillSet: Bool {
        Set(installedSkillNames) == Set(expectedSkillNames)
    }

    var managedSkillsEnabled: Bool {
        expectedSkillNames.isEmpty == false
            && expectedSkillNames.allSatisfy { $0.hasPrefix("\(CodexSessionIntegrationContract.pluginName):") }
            && hasExactPluginSkillSet
            && Set(enabledSkillNames).isSuperset(of: expectedSkillNames)
    }

    var parsedAllSessionHooks: Bool {
        let expectedEvents = CodexSessionIntegrationContract.hookDefinitions.map(\.event)
        return sessionHooks.count == expectedEvents.count
            && Set(sessionHooks.map(\.event)) == Set(expectedEvents)
            && sessionHooks.allSatisfy(\.definitionMatchesExpected)
    }

    var allSessionHooksTrusted: Bool {
        parsedAllSessionHooks && sessionHooks.allSatisfy { $0.trust == .trusted }
    }

    var canUseSessionIntegrations: Bool {
        support == .supported
            && managedSkillsEnabled
            && allSessionHooksTrusted
            && legacyGlobalHooksPresent == false
            && errors.isEmpty
    }

    var canInjectSessionConfiguration: Bool {
        support == .supported && managedSkillsEnabled && parsedAllSessionHooks && errors.isEmpty
    }
}

struct CodexPluginSkillManifest: Equatable, Sendable {
    let pluginName: String
    let skillsRootURL: URL
    let skillNames: [String]

    var qualifiedSkillNames: [String] {
        skillNames.map { "\(pluginName):\($0)" }
    }
}

enum CodexPluginSkillManifestError: LocalizedError, Equatable {
    case unreadableManifest(String)
    case invalidManifest(String)
    case invalidSkillsPath(String)
    case unreadableSkillsDirectory(String)
    case invalidSkillFile(String)
    case duplicateSkillName(String)

    var errorDescription: String? {
        switch self {
        case .unreadableManifest(let path):
            return "Unable to read Codex plugin manifest: \(path)"
        case .invalidManifest(let path):
            return "Codex plugin manifest is invalid: \(path)"
        case .invalidSkillsPath(let path):
            return "Codex plugin skills path must stay inside the plugin: \(path)"
        case .unreadableSkillsDirectory(let path):
            return "Unable to read Codex plugin skills directory: \(path)"
        case .invalidSkillFile(let path):
            return "Codex plugin skill is missing a valid frontmatter name: \(path)"
        case .duplicateSkillName(let name):
            return "Codex plugin contains a duplicate skill name: \(name)"
        }
    }
}

enum CodexPluginSkillManifestReader {
    private struct PluginManifest: Decodable {
        let name: String
        let skills: String
    }

    static func read(
        pluginDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> CodexPluginSkillManifest {
        let pluginRoot = pluginDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let manifestURL = pluginRoot
            .appendingPathComponent(".codex-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json", isDirectory: false)

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw CodexPluginSkillManifestError.unreadableManifest(manifestURL.path)
        }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw CodexPluginSkillManifestError.invalidManifest(manifestURL.path)
        }

        guard let pluginName = normalizedName(manifest.name),
              pluginName == CodexSessionIntegrationContract.pluginName,
              manifest.skills.hasPrefix("/") == false else {
            throw CodexPluginSkillManifestError.invalidManifest(manifestURL.path)
        }

        let skillsRoot = pluginRoot
            .appendingPathComponent(manifest.skills, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard skillsRoot.path == pluginRoot.path
                || skillsRoot.path.hasPrefix(pluginRoot.path.appending("/")) else {
            throw CodexPluginSkillManifestError.invalidSkillsPath(skillsRoot.path)
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: skillsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CodexPluginSkillManifestError.unreadableSkillsDirectory(skillsRoot.path)
        }

        var names = Set<String>()
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else {
                continue
            }
            let skillURL = child.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: skillURL.path) else {
                continue
            }
            guard let contents = try? String(contentsOf: skillURL, encoding: .utf8),
                  let name = frontmatterName(in: contents) else {
                throw CodexPluginSkillManifestError.invalidSkillFile(skillURL.path)
            }
            guard names.insert(name).inserted else {
                throw CodexPluginSkillManifestError.duplicateSkillName(name)
            }
        }

        guard names.isEmpty == false else {
            throw CodexPluginSkillManifestError.unreadableSkillsDirectory(skillsRoot.path)
        }
        return CodexPluginSkillManifest(
            pluginName: pluginName,
            skillsRootURL: skillsRoot,
            skillNames: names.sorted()
        )
    }

    private static func frontmatterName(in contents: String) -> String? {
        let normalizedContents = contents.hasPrefix("\u{FEFF}")
            ? String(contents.dropFirst())
            : contents
        let lines = normalizedContents.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return nil
        }
        var candidateName: String?
        for line in lines.dropFirst() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "---" {
                return candidateName
            }
            guard line.first?.isWhitespace != true,
                  text.hasPrefix("name:") else {
                continue
            }
            let value = text.dropFirst("name:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            candidateName = normalizedName(unquoting(value))
        }
        return nil
    }

    private static func unquoting(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func normalizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }
}

enum CodexSessionConfigSerializer {
    static func skillsConfigOverride(enabling skillNames: [String]) -> String {
        let entries = Set(skillNames).sorted().map { name in
            "{name=\(tomlBasicStringLiteral(name)),enabled=true}"
        }
        return "skills.config=[\(entries.joined(separator: ","))]"
    }

    static func hooksOverride(
        definitions: [CodexSessionHookDefinition],
        command: String,
        timeoutSeconds: Int,
        statusMessage: String
    ) -> String {
        let hook = "{type=\(tomlBasicStringLiteral("command")),command=\(tomlBasicStringLiteral(command)),timeout=\(timeoutSeconds),statusMessage=\(tomlBasicStringLiteral(statusMessage))}"
        let entries = definitions.map { definition in
            let matcher = definition.matcher.map {
                "matcher=\(tomlBasicStringLiteral($0)),"
            } ?? ""
            return "\(definition.event.rawValue)=[{\(matcher)hooks=[\(hook)]}]"
        }
        return "hooks={\(entries.joined(separator: ","))}"
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
