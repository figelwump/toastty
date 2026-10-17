import Foundation
import RemoteProtocol

public enum TaskCreateScriptOutputError: Error, Equatable, Sendable {
    case missingJSONLine
    case invalidJSON
    case missingDirectory
    case directoryNotAbsolute(String)
}

/// The create script's contract: its last non-empty stdout line is a JSON
/// object with a required `directory` and optional `branch` and `baseRef`.
public enum TaskCreateScriptOutput {
    public static func parse(stdout: String, homeDirectoryPath: String = NSHomeDirectory()) throws -> TaskInboxItem.CreatedDirectory {
        guard let line = lastNonEmptyLine(stdout) else { throw TaskCreateScriptOutputError.missingJSONLine }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw TaskCreateScriptOutputError.invalidJSON
        }
        guard let rawDirectory = (object["directory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawDirectory.isEmpty == false else {
            throw TaskCreateScriptOutputError.missingDirectory
        }
        let directory = expandingTilde(rawDirectory, homeDirectoryPath: homeDirectoryPath)
        guard directory.hasPrefix("/") else { throw TaskCreateScriptOutputError.directoryNotAbsolute(rawDirectory) }
        return TaskInboxItem.CreatedDirectory(
            directory: (directory as NSString).standardizingPath,
            branch: nonEmptyString(object["branch"]),
            baseRef: nonEmptyString(object["baseRef"])
        )
    }

    /// The line a failed script leaves for the user: its last non-empty
    /// stderr line, shortened.
    public static func failureDetail(stderr: String) -> String? {
        lastNonEmptyLine(stderr).map { String($0.prefix(200)) }
    }

    public static func expandingTilde(_ path: String, homeDirectoryPath: String) -> String {
        if path == "~" { return homeDirectoryPath }
        if path.hasPrefix("~/") { return homeDirectoryPath + String(path.dropFirst(1)) }
        return path
    }

    static func lastNonEmptyLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.isEmpty == false }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              string.isEmpty == false else { return nil }
        return String(string.prefix(200))
    }
}

/// The first prompt of a task's agent.
public enum TaskStartPrompt {
    public static let userSkillPluginName = "toastty-user"

    /// How the agent is asked to use `skill`. Claude and Codex get their own
    /// skill syntax, under Toastty's user-skill plugin name when the skill is
    /// one of the user's accepted skills. Other agents load user skills
    /// without that name, and their syntax is not verified, so they get a
    /// plain request.
    public static func skillLine(skill: String, agent: AgentKind, isUserSkill: Bool) -> String {
        let name = isUserSkill ? "\(userSkillPluginName):\(skill)" : skill
        switch agent {
        case .claude: return "/\(name)"
        case .codex: return "$\(name)"
        default: return "Use the \(skill) skill for this task."
        }
    }

    public static func compose(
        skillLine: String?,
        text: String,
        attachmentPaths: [String],
        plan: TaskInboxItem.Plan,
        workspaceTitle: String,
        directory: String,
        createdDirectory: TaskInboxItem.CreatedDirectory?
    ) -> String {
        var sections: [String] = []
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let skillLine {
            sections.append(body.isEmpty ? skillLine : skillLine + "\n" + body)
        } else if body.hasPrefix("-") {
            // A prompt that starts with a dash could read as an option.
            sections.append("Task:\n" + body)
        } else if body.isEmpty == false {
            sections.append(body)
        }
        if attachmentPaths.isEmpty == false {
            sections.append(
                "Read the following files attached to this task on this Mac:\n"
                    + attachmentPaths.map(TerminalDropPayloadBuilder.shellEscapedPath).joined(separator: "\n")
            )
        }
        var context = [
            "Task space: \(plan.slug), in workspace \(workspaceTitle)",
            "Directory: \(directory)",
        ]
        if let branch = createdDirectory?.branch {
            context.append(
                createdDirectory?.baseRef.map { "Branch: \(branch), from \($0)" } ?? "Branch: \(branch)"
            )
        }
        sections.append(context.joined(separator: "\n"))
        return sections.joined(separator: "\n\n")
    }
}
