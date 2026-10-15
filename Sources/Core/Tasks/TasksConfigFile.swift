import Foundation
import RemoteProtocol

public struct TasksConfigParseError: LocalizedError, Equatable, Sendable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var errorDescription: String? {
        "tasks.toml line \(line): \(message)"
    }
}

/// How quick tasks are placed, set up and started. Every section is
/// optional: without `[triage]` each task needs a workspace from the user,
/// without `[create]` the task space opens in the workspace's own
/// directory, and without `[start]` the first prompt is the task alone.
public struct TasksConfig: Equatable, Sendable {
    public struct Triage: Equatable, Sendable {
        public static let defaultTimeoutSeconds = 60
        public static let timeoutRange = 5...600

        /// An agent profile ID. Only Claude and Codex have a headless mode
        /// that triage can use; the app checks the executable.
        public var profileID: String
        public var model: String?
        public var effort: String?
        public var timeoutSeconds: Int
        /// The user's own rules, given to the triage model as written.
        public var guidance: String?

        public init(
            profileID: String,
            model: String? = nil,
            effort: String? = nil,
            timeoutSeconds: Int = defaultTimeoutSeconds,
            guidance: String? = nil
        ) {
            self.profileID = profileID
            self.model = model
            self.effort = effort
            self.timeoutSeconds = timeoutSeconds
            self.guidance = guidance
        }
    }

    public struct Create: Equatable, Sendable {
        public static let defaultTimeoutSeconds = 120
        public static let timeoutRange = 5...1800

        /// As written in the file; a leading `~` is expanded when it runs.
        public var script: String
        public var timeoutSeconds: Int

        public init(script: String, timeoutSeconds: Int = defaultTimeoutSeconds) {
            self.script = script
            self.timeoutSeconds = timeoutSeconds
        }
    }

    public struct Start: Equatable, Sendable {
        /// A skill name, sent as the first line of the first prompt in the
        /// agent's own syntax.
        public var skill: String

        public init(skill: String) {
            self.skill = skill
        }
    }

    public var triage: Triage?
    public var create: Create?
    public var start: Start?

    public init(triage: Triage? = nil, create: Create? = nil, start: Start? = nil) {
        self.triage = triage
        self.create = create
        self.start = start
    }

    public static let empty = TasksConfig()
}

public enum TasksConfigFile {
    public static let environmentOverrideKey = "TOASTTY_TASKS_CONFIG_PATH"
    public static let maximumSkillNameLength = 64

    public static func fileURL(
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let overrideURL = overrideFileURL(environment: environment) {
            return overrideURL
        }
        return ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        ).tasksConfigFileURL
    }

    private static func overrideFileURL(environment: [String: String]) -> URL? {
        guard let rawOverridePath = environment[environmentOverrideKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawOverridePath.isEmpty == false else {
            return nil
        }
        return URL(filePath: (rawOverridePath as NSString).expandingTildeInPath)
    }

    public static func ensureTemplateExists(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        // Override paths are for tests and automation; never create files
        // outside the standard Toastty config location.
        if overrideFileURL(environment: environment) != nil {
            return
        }
        let url = fileURL(homeDirectoryPath: homeDirectoryPath, environment: environment)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try Data(templateContents().utf8).write(to: url, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return
        }
    }

    public static func load(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TasksConfig {
        let url = fileURL(homeDirectoryPath: homeDirectoryPath, environment: environment)
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try parse(contents: contents)
    }

    public static func parse(contents: String) throws -> TasksConfig {
        try TasksConfigParser.parse(contents: contents)
    }

    /// A skill name Toastty may put in a prompt: ASCII letters, digits,
    /// `.`, `_` and `-`, not starting with `.`.
    public static func isValidSkillName(_ value: String) -> Bool {
        guard value.isEmpty == false,
              value.count <= maximumSkillNameLength,
              value.hasPrefix(".") == false else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-")
        }
    }

    public static func templateContents() -> String {
        """
        # Toastty quick tasks
        #
        # A quick task goes to the Inbox at the top of the sidebar. Toastty
        # then picks a workspace for it (triage), makes its directory (create)
        # and starts an agent in a new task space with your guidance (start).
        # Every section is optional. After saving, use Toastty > Reload
        # Configuration.
        #
        # [triage] — a model that picks the workspace, agent, model and effort.
        # Without it, each task needs a workspace from you.
        #   profile          — "claude" or "codex", from agents.toml. Triage runs
        #                      that CLI headless, with no tools.
        #   model, effort    — (optional) for the triage call itself.
        #   timeout-seconds  — (optional) default 60.
        #   guidance         — (optional) your rules, given to the model as
        #                      written. Use triple quotes for several lines.
        #
        # [triage]
        # profile = "claude"
        # model = "claude-haiku-5-5"
        # effort = "low"
        # timeout-seconds = 60
        # guidance = \"\"\"
        # toastty is the macOS and iOS app. website is the marketing site.
        # Hard or unclear work: claude, claude-opus-5-5, xhigh.
        # Clear, bounded work: codex, gpt-6.1-sol, high.
        # \"\"\"
        #
        # [create] — a script that makes the task's directory, such as a git
        # worktree. Without it, the task space opens in the workspace's own
        # directory. The script runs in the workspace's directory with
        # TOASTTY_TASK_ID, TOASTTY_TASK_SLUG, TOASTTY_TASK_BRANCH_PREFIX and
        # TOASTTY_TASK_TITLE set. Its last line on stdout must be JSON:
        #   {"directory": "/absolute/path", "branch": "...", "baseRef": "..."}
        # Only "directory" is required. Exit 0 for success; on failure, the
        # last line on stderr is shown.
        #
        # [create]
        # script = "~/.toastty/skills/worktree-create/scripts/task-create.sh"
        # timeout-seconds = 120
        #
        # [start] — a skill sent as the first line of the agent's first
        # prompt, before the task text, in the agent's own syntax.
        #
        # [start]
        # skill = "task-start"
        """
            + "\n"
    }
}

private enum TasksConfigParser {
    private enum Table: String {
        case triage
        case create
        case start
    }

    private enum Value {
        case string(String)
        case integer(Int)
    }

    static func parse(contents: String) throws -> TasksConfig {
        let lines = contents.components(separatedBy: .newlines)
        var values: [Table: [String: (value: Value, line: Int)]] = [:]
        var tableLines: [Table: Int] = [:]
        var currentTable: Table?

        var lineIndex = 0
        while lineIndex < lines.count {
            let lineNumber = lineIndex + 1
            let trimmedLine = stripComment(from: lines[lineIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lineIndex += 1
            guard trimmedLine.isEmpty == false else { continue }

            if trimmedLine.hasPrefix("[") {
                guard trimmedLine.hasSuffix("]") else {
                    throw TasksConfigParseError(line: lineNumber, message: "invalid table header")
                }
                let name = String(trimmedLine.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let table = Table(rawValue: name) else {
                    throw TasksConfigParseError(
                        line: lineNumber,
                        message: "unknown table [\(name)]; expected [triage], [create] or [start]"
                    )
                }
                guard tableLines[table] == nil else {
                    throw TasksConfigParseError(line: lineNumber, message: "duplicate table [\(name)]")
                }
                tableLines[table] = lineNumber
                values[table] = [:]
                currentTable = table
                continue
            }

            guard let equalsIndex = trimmedLine.firstIndex(of: "=") else {
                throw TasksConfigParseError(line: lineNumber, message: "expected key = value")
            }
            guard let table = currentTable else {
                throw TasksConfigParseError(
                    line: lineNumber,
                    message: "expected a [triage], [create] or [start] table before keys"
                )
            }
            let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = trimmedLine[trimmedLine.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard values[table]?[key] == nil else {
                throw TasksConfigParseError(line: lineNumber, message: "[\(table.rawValue)] has duplicate \(key)")
            }

            let value: Value
            if rawValue.hasPrefix("\"\"\"") {
                // The raw line keeps any text after the opening quotes; a
                // `#` inside a multiline string is text, not a comment.
                let rawLine = lines[lineIndex - 1]
                guard let openRange = rawLine.range(of: "\"\"\"") else {
                    throw TasksConfigParseError(line: lineNumber, message: "invalid multiline string")
                }
                var text = String(rawLine[openRange.upperBound...])
                var closed = false
                if let closeRange = text.range(of: "\"\"\"") {
                    guard text[closeRange.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else {
                        throw TasksConfigParseError(line: lineNumber, message: "unexpected text after closing \"\"\"")
                    }
                    text = String(text[..<closeRange.lowerBound])
                    closed = true
                } else {
                    var bodyLines: [String] = text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [text]
                    while lineIndex < lines.count {
                        let bodyLine = lines[lineIndex]
                        lineIndex += 1
                        if let closeRange = bodyLine.range(of: "\"\"\"") {
                            guard bodyLine[closeRange.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else {
                                throw TasksConfigParseError(
                                    line: lineIndex,
                                    message: "unexpected text after closing \"\"\""
                                )
                            }
                            let tail = String(bodyLine[..<closeRange.lowerBound])
                            if tail.trimmingCharacters(in: .whitespaces).isEmpty == false {
                                bodyLines.append(tail)
                            }
                            closed = true
                            break
                        }
                        bodyLines.append(bodyLine)
                    }
                    text = bodyLines.joined(separator: "\n")
                }
                guard closed else {
                    throw TasksConfigParseError(line: lineNumber, message: "unterminated multiline string")
                }
                value = .string(text)
            } else if rawValue.hasPrefix("\"") {
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(rawValue.utf8)) else {
                    throw TasksConfigParseError(line: lineNumber, message: "[\(table.rawValue)] has invalid \(key)")
                }
                value = .string(decoded)
            } else if let integer = Int(rawValue.replacingOccurrences(of: "_", with: "")),
                      rawValue.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "_") }) {
                value = .integer(integer)
            } else {
                throw TasksConfigParseError(
                    line: lineNumber,
                    message: "[\(table.rawValue)] \(key) must be a quoted string or a whole number"
                )
            }
            values[table, default: [:]][key] = (value, lineNumber)
        }

        return TasksConfig(
            triage: try tableLines[.triage].map { try triage(values[.triage] ?? [:], tableLine: $0) },
            create: try tableLines[.create].map { try create(values[.create] ?? [:], tableLine: $0) },
            start: try tableLines[.start].map { try start(values[.start] ?? [:], tableLine: $0) }
        )
    }

    private typealias Entries = [String: (value: Value, line: Int)]

    private static func triage(_ entries: Entries, tableLine: Int) throws -> TasksConfig.Triage {
        try rejectUnknownKeys(entries, table: .triage, allowed: ["profile", "model", "effort", "timeout-seconds", "guidance"])
        guard let profile = try string("profile", in: entries, table: .triage) else {
            throw TasksConfigParseError(line: tableLine, message: "[triage] is missing profile")
        }
        guard AgentKind(rawValue: profile) != nil else {
            throw TasksConfigParseError(line: entries["profile"]!.line, message: "[triage] profile '\(profile)' is not a profile ID")
        }
        let model = try string("model", in: entries, table: .triage)
        if let model, RemoteSessionStartPolicy.isValidSelectionValue(model, maximumLength: RemoteSessionStartPolicy.maximumModelLength) == false {
            throw TasksConfigParseError(line: entries["model"]!.line, message: "[triage] model must be one word with no spaces that doesn't start with a dash")
        }
        let effort = try string("effort", in: entries, table: .triage)
        if let effort, RemoteSessionStartPolicy.isValidSelectionValue(effort, maximumLength: RemoteSessionStartPolicy.maximumReasoningEffortLength) == false {
            throw TasksConfigParseError(line: entries["effort"]!.line, message: "[triage] effort must be one word with no spaces that doesn't start with a dash")
        }
        let guidance = try string("guidance", in: entries, table: .triage)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return TasksConfig.Triage(
            profileID: profile,
            model: model,
            effort: effort,
            timeoutSeconds: try timeout(in: entries, table: .triage, range: TasksConfig.Triage.timeoutRange)
                ?? TasksConfig.Triage.defaultTimeoutSeconds,
            guidance: guidance?.isEmpty == true ? nil : guidance
        )
    }

    private static func create(_ entries: Entries, tableLine: Int) throws -> TasksConfig.Create {
        try rejectUnknownKeys(entries, table: .create, allowed: ["script", "timeout-seconds"])
        guard let script = try string("script", in: entries, table: .create) else {
            throw TasksConfigParseError(line: tableLine, message: "[create] is missing script")
        }
        return TasksConfig.Create(
            script: script,
            timeoutSeconds: try timeout(in: entries, table: .create, range: TasksConfig.Create.timeoutRange)
                ?? TasksConfig.Create.defaultTimeoutSeconds
        )
    }

    private static func start(_ entries: Entries, tableLine: Int) throws -> TasksConfig.Start {
        try rejectUnknownKeys(entries, table: .start, allowed: ["skill"])
        guard let skill = try string("skill", in: entries, table: .start) else {
            throw TasksConfigParseError(line: tableLine, message: "[start] is missing skill")
        }
        guard TasksConfigFile.isValidSkillName(skill) else {
            throw TasksConfigParseError(
                line: entries["skill"]!.line,
                message: "[start] skill must be 1-\(TasksConfigFile.maximumSkillNameLength) ASCII letters, digits, '.', '_' or '-', and not start with '.'"
            )
        }
        return TasksConfig.Start(skill: skill)
    }

    private static func rejectUnknownKeys(_ entries: Entries, table: Table, allowed: Set<String>) throws {
        if let unknown = entries.filter({ allowed.contains($0.key) == false }).min(by: { $0.value.line < $1.value.line }) {
            throw TasksConfigParseError(line: unknown.value.line, message: "[\(table.rawValue)] contains unknown key '\(unknown.key)'")
        }
    }

    /// A present string, trimmed; `nil` when the key is absent. An empty
    /// value is an error, so a typo cannot silently turn a setting off.
    private static func string(_ key: String, in entries: Entries, table: Table) throws -> String? {
        guard let entry = entries[key] else { return nil }
        guard case .string(let raw) = entry.value else {
            throw TasksConfigParseError(line: entry.line, message: "[\(table.rawValue)] \(key) must be a quoted string")
        }
        let value = key == "guidance" ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TasksConfigParseError(line: entry.line, message: "[\(table.rawValue)] \(key) is empty")
        }
        return value
    }

    private static func timeout(in entries: Entries, table: Table, range: ClosedRange<Int>) throws -> Int? {
        guard let entry = entries["timeout-seconds"] else { return nil }
        guard case .integer(let seconds) = entry.value, range.contains(seconds) else {
            throw TasksConfigParseError(
                line: entry.line,
                message: "[\(table.rawValue)] timeout-seconds must be a whole number from \(range.lowerBound) to \(range.upperBound)"
            )
        }
        return seconds
    }

    private static func stripComment(from line: String) -> String {
        var result = ""
        var isInsideString = false
        var isEscaping = false
        for character in line {
            if isEscaping {
                result.append(character)
                isEscaping = false
                continue
            }
            if character == "\\" && isInsideString {
                result.append(character)
                isEscaping = true
                continue
            }
            if character == "\"" {
                isInsideString.toggle()
            } else if character == "#" && isInsideString == false {
                break
            }
            result.append(character)
        }
        return result
    }
}
