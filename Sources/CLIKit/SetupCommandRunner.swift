import RemoteProtocol
import CoreState
import Foundation

enum SetupGuideFormat: String, CaseIterable, Codable, Equatable {
    case text
    case md
}

enum SetupCommand: Equatable {
    case guide(format: SetupGuideFormat)
    case skillsList
    case installShellIntegration(shell: ProfileShellIntegrationShell?, apply: Bool)
    case installHooks(agent: AgentKind, apply: Bool)
}

struct SetupResourceStore {
    let setupDirectoryURL: URL

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
            )
            writeStdout(execution.output)
            return execution.exitCode
        }

        let output = try render(
            command: command,
            jsonOutput: jsonOutput,
            store: .live(environment: environment),
            environment: environment
        )
        writeStdout(output)
        return 0
    }

    static func render(
        command: SetupCommand,
        jsonOutput: Bool,
        store: SetupResourceStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> String {
        switch command {
        case .guide(let format):
            let content = try store.guide(format: format)
            if jsonOutput {
                return try renderJSON(GuidePayload(format: format, content: content))
            }
            return content

        case .skillsList:
            let inventory = SetupSkillsInventory(
                environment: environment,
                fileManager: fileManager
            )
            if jsonOutput {
                return try renderJSON(inventory.payload)
            }
            return inventory.renderText()

        case .installShellIntegration, .installHooks:
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
        case .installShellIntegration, .installHooks:
            return true
        case .guide, .skillsList:
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

private enum SetupSkillSource: String, Codable {
    case shipped
    case user
}

private enum SetupSkillInclusion: String, Codable {
    case included
    case excluded
}

private struct SetupSkillListItem: Codable {
    let name: String
    let source: SetupSkillSource
    let inclusion: SetupSkillInclusion
    let summary: String?
    let diagnosticCode: String?
    let diagnosticMessage: String?
}

private struct SetupSkillsListPayload: Codable {
    let schemaVersion: Int
    let userSkillsRoot: String
    let skills: [SetupSkillListItem]
    let globalDiagnostics: [String]
}

private struct SetupSkillsInventory {
    let payload: SetupSkillsListPayload

    init(environment: [String: String], fileManager: FileManager) {
        let runtimePaths = ToasttyRuntimePaths.resolve(environment: environment)
        let rootURL = runtimePaths.userSkillsDirectoryURL
        let state = ToasttyUserSkillValidator(fileManager: fileManager)
            .scan(userSkillsDirectoryURL: rootURL)
            .state
        let shipped = ToasttyShippedSkillCatalog.skills.map { skill in
            SetupSkillListItem(
                name: skill.name,
                source: .shipped,
                inclusion: .included,
                summary: skill.summary,
                diagnosticCode: nil,
                diagnosticMessage: nil
            )
        }
        let user = state.packages.map { package in
            switch package.status {
            case .accepted:
                return SetupSkillListItem(
                    name: package.name,
                    source: .user,
                    inclusion: .included,
                    summary: nil,
                    diagnosticCode: nil,
                    diagnosticMessage: nil
                )
            case .excluded(let diagnostic):
                return SetupSkillListItem(
                    name: package.name,
                    source: .user,
                    inclusion: .excluded,
                    summary: nil,
                    diagnosticCode: diagnostic.code,
                    diagnosticMessage: diagnostic.displayMessage
                )
            }
        }
        payload = SetupSkillsListPayload(
            schemaVersion: 1,
            userSkillsRoot: rootURL.path,
            skills: shipped + user,
            globalDiagnostics: state.globalDiagnostics.map(\.code)
        )
    }

    func renderText() -> String {
        let shipped = payload.skills.filter { $0.source == .shipped }
        let includedUser = payload.skills.filter {
            $0.source == .user && $0.inclusion == .included
        }
        let excludedUser = payload.skills.filter {
            $0.source == .user && $0.inclusion == .excluded
        }

        var lines = [
            "Skills available to new supported managed launches",
            "",
            "Shipped skills:",
        ]
        lines.append(contentsOf: shipped.map { item in
            "- toastty:\(item.name) — \(item.summary ?? "")"
        })
        lines.append("")
        lines.append("User skills (\(payload.userSkillsRoot)):")
        if includedUser.isEmpty {
            lines.append("- None found")
        } else {
            lines.append(contentsOf: includedUser.map { "- \($0.name)" })
        }
        if excludedUser.isEmpty == false {
            lines.append("")
            lines.append("Excluded user packages:")
            lines.append(contentsOf: excludedUser.map { item in
                "- \(item.name): \(item.diagnosticMessage ?? "Excluded")"
            })
        }
        lines.append("")
        lines.append("Running sessions keep the skills they launched with. Unsupported or failed managed delivery proceeds without Toastty skills.")
        return lines.joined(separator: "\n")
    }
}
