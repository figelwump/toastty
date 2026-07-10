import CoreState
import Foundation

enum SetupGuideFormat: String, CaseIterable, Codable, Equatable {
    case text
    case md
}

enum SetupCommand: Equatable {
    case guide(format: SetupGuideFormat)
    case skillsList
    case printSkill(name: String)
    case installShellIntegration(shell: ProfileShellIntegrationShell?, apply: Bool)
    case installHooks(agent: AgentKind, apply: Bool)
    case installSkill(name: String, runtime: SetupSkillRuntime, apply: Bool)
}

enum StarterSkill: String, CaseIterable, Codable, Equatable {
    case toasttyCapabilities = "toastty-capabilities"
    case toasttyScratchpad = "toastty-scratchpad"
    case toasttyOpenMarkdown = "toastty-open-markdown"
}

enum SetupSkillRuntime: String, CaseIterable, Codable, Equatable {
    case agents
    case claude
    case codex
    case all
}

struct SetupResourceStore {
    let setupDirectoryURL: URL
    var fileManager: FileManager = .default

    static func live(environment: [String: String]) -> Self {
        SetupResourceStore(
            setupDirectoryURL: SetupResourceResolver.setupDirectoryURL(environment: environment)
        )
    }

    func guideMarkdown() throws -> String {
        try readUTF8(setupDirectoryURL.appendingPathComponent("onboarding-guide.md", isDirectory: false))
    }

    func guide(format: SetupGuideFormat) throws -> String {
        let markdown = try guideMarkdown()
        switch format {
        case .md:
            return markdown
        case .text:
            return SetupGuideTextRenderer.render(markdown: markdown)
        }
    }

    func listSkillNames() throws -> [String] {
        let starterSkillsURL = setupDirectoryURL.appendingPathComponent("starter-skills", isDirectory: true)
        return try StarterSkill.allCases.map { skill in
            let skillURL = starterSkillsURL.appendingPathComponent(skill.rawValue, isDirectory: true)
            let skillMarkdownURL = skillURL.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: skillMarkdownURL.path) else {
                throw ToasttyCLIError.runtime("missing bundled starter skill: \(skill.rawValue)")
            }
            return skill.rawValue
        }
    }

    func skillMarkdown(name: String) throws -> String {
        guard StarterSkill(rawValue: name) != nil else {
            throw ToasttyCLIError.usage("unknown starter skill: \(name)")
        }
        let skillMarkdownURL = setupDirectoryURL
            .appendingPathComponent("starter-skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
        return try readUTF8(skillMarkdownURL)
    }

    private func readUTF8(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ToasttyCLIError.runtime("failed to read setup resource \(url.path): \(error.localizedDescription)")
        }
    }
}

enum SetupCommandRunner {
    static func run(
        command: SetupCommand,
        jsonOutput: Bool,
        environment: [String: String]
    ) throws -> Int32 {
        if command.isInstallerCommand {
            let execution = try SetupInstallerCommandRunner.execute(
                command: command,
                jsonOutput: jsonOutput,
                environment: environment,
                store: .live(environment: environment)
            )
            writeStdout(execution.output)
            return execution.exitCode
        }

        let output = try render(
            command: command,
            jsonOutput: jsonOutput,
            store: .live(environment: environment)
        )
        writeStdout(output)
        return 0
    }

    static func render(
        command: SetupCommand,
        jsonOutput: Bool,
        store: SetupResourceStore
    ) throws -> String {
        switch command {
        case .guide(let format):
            let content = try store.guide(format: format)
            if jsonOutput {
                return try renderJSON(GuidePayload(format: format, content: content))
            }
            return content

        case .skillsList:
            let skills = try store.listSkillNames()
            if jsonOutput {
                return try renderJSON(SkillsListPayload(skills: skills))
            }
            return skills.joined(separator: "\n")

        case .printSkill(let name):
            let content = try store.skillMarkdown(name: name)
            if jsonOutput {
                return try renderJSON(SkillPayload(name: name, content: content))
            }
            return content

        case .installShellIntegration, .installHooks, .installSkill:
            throw ToasttyCLIError.runtime("setup installer commands require a launch environment")
        }
    }

    private static func renderJSON<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ToasttyCLIError.runtime("failed to encode setup response")
        }
        return string
    }

    private static func writeStdout(_ string: String) {
        let output = string.hasSuffix("\n") ? string : string + "\n"
        FileHandle.standardOutput.write(output.data(using: .utf8) ?? Data())
    }
}

private extension SetupCommand {
    var isInstallerCommand: Bool {
        switch self {
        case .installShellIntegration, .installHooks, .installSkill:
            return true
        case .guide, .skillsList, .printSkill:
            return false
        }
    }
}

private enum SetupGuideTextRenderer {
    static func render(markdown: String) -> String {
        var rendered: [String] = []
        var inCodeFence = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCodeFence.toggle()
                continue
            }
            if inCodeFence {
                rendered.append(rawLine)
                continue
            }
            if line.hasPrefix("#") {
                rendered.append(String(line.drop(while: { $0 == "#" || $0 == " " })))
            } else {
                rendered.append(rawLine)
            }
        }

        return rendered.joined(separator: "\n")
    }
}

private struct GuidePayload: Codable {
    var format: SetupGuideFormat
    var content: String
}

private struct SkillsListPayload: Codable {
    var skills: [String]
}

private struct SkillPayload: Codable {
    var name: String
    var content: String
}
