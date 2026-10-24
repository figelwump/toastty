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

/// The settings in `~/.toastty/tasks.toml`. Every table is optional.
///
/// The `*_skill` keys name the skill Toastty points an agent to at each
/// task event: the first message, Merge and Release. Toastty does not check
/// that the agent has the skill.
public struct TasksConfig: Equatable, Sendable {
    public enum MergeMode: String, Equatable, Sendable {
        /// Merge sends `merge_prompt` to the task's agent, which checks the
        /// pull request before it merges.
        case agent
        /// Merge acts at once, with no agent.
        case direct
    }

    public struct Triage: Equatable, Sendable {
        public static let defaultTimeoutSeconds = 120
        public static let timeoutRange = 5...600

        /// The command line Toastty runs to place a task, with its model
        /// and effort.
        public var command: String?
        public var guidelines: String?
        public var guidelinesFile: String?
        public var timeoutSeconds: Int

        public init(
            command: String? = nil,
            guidelines: String? = nil,
            guidelinesFile: String? = nil,
            timeoutSeconds: Int = defaultTimeoutSeconds
        ) {
            self.command = command
            self.guidelines = guidelines
            self.guidelinesFile = guidelinesFile
            self.timeoutSeconds = timeoutSeconds
        }
    }

    /// Used for any field the caller and triage leave out.
    public struct Defaults: Equatable, Sendable {
        public var agent: String?
        public var model: String?
        public var effort: String?
        public var merge: MergeMode?
        public var mergePrompt: String?
        public var startSkill: String?
        public var mergeSkill: String?
        public var releaseSkill: String?

        public init(
            agent: String? = nil,
            model: String? = nil,
            effort: String? = nil,
            merge: MergeMode? = nil,
            mergePrompt: String? = nil,
            startSkill: String? = nil,
            mergeSkill: String? = nil,
            releaseSkill: String? = nil
        ) {
            self.agent = agent
            self.model = model
            self.effort = effort
            self.merge = merge
            self.mergePrompt = mergePrompt
            self.startSkill = startSkill
            self.mergeSkill = mergeSkill
            self.releaseSkill = releaseSkill
        }
    }

    public struct QuickEntry: Equatable, Sendable {
        /// The global shortcut for the quick entry panel; nil when the file
        /// turns it off with `shortcut = "none"`.
        public var shortcut: QuickEntryShortcut?

        public init(shortcut: QuickEntryShortcut? = .default) {
            self.shortcut = shortcut
        }
    }

    /// The coordinator: one agent session that Toastty starts at launch in a
    /// hidden workspace, and starts again when it exits.
    public struct Coordinator: Equatable, Sendable {
        public static let defaultAgent = "claude"

        /// The agent profile to run; nil when the file turns the
        /// coordinator off with `agent = "none"`.
        public var agent: String?
        public var model: String?
        public var effort: String?

        public init(agent: String? = defaultAgent, model: String? = nil, effort: String? = nil) {
            self.agent = agent
            self.model = model
            self.effort = effort
        }
    }

    /// Settings for the tasks of one project, matched on the project's root
    /// directory.
    public struct Workspace: Equatable, Sendable {
        /// The root directory as written in the file.
        public var path: String
        public var guidelines: String?
        public var createHook: String?
        public var branchPrefix: String?
        public var releaseTags: String?
        public var releasePrompt: String?
        public var merge: MergeMode?
        public var mergePrompt: String?
        public var startSkill: String?
        public var mergeSkill: String?
        public var releaseSkill: String?

        public init(
            path: String,
            guidelines: String? = nil,
            createHook: String? = nil,
            branchPrefix: String? = nil,
            releaseTags: String? = nil,
            releasePrompt: String? = nil,
            merge: MergeMode? = nil,
            mergePrompt: String? = nil,
            startSkill: String? = nil,
            mergeSkill: String? = nil,
            releaseSkill: String? = nil
        ) {
            self.path = path
            self.guidelines = guidelines
            self.createHook = createHook
            self.branchPrefix = branchPrefix
            self.releaseTags = releaseTags
            self.releasePrompt = releasePrompt
            self.merge = merge
            self.mergePrompt = mergePrompt
            self.startSkill = startSkill
            self.mergeSkill = mergeSkill
            self.releaseSkill = releaseSkill
        }
    }

    public var triage: Triage?
    public var defaults: Defaults
    public var quickEntry: QuickEntry
    public var coordinator: Coordinator
    /// In file order.
    public var workspaces: [Workspace]

    public init(
        triage: Triage? = nil,
        defaults: Defaults = Defaults(),
        quickEntry: QuickEntry = QuickEntry(),
        coordinator: Coordinator = Coordinator(),
        workspaces: [Workspace] = []
    ) {
        self.triage = triage
        self.defaults = defaults
        self.quickEntry = quickEntry
        self.coordinator = coordinator
        self.workspaces = workspaces
    }

    public static let empty = TasksConfig()

    /// The section for a project root, compared after expanding `~` and
    /// resolving symbolic links on both sides.
    public func workspace(forProjectRoot projectRoot: String, homeDirectoryPath: String = NSHomeDirectory()) -> Workspace? {
        let target = TasksConfigFile.normalizedPath(projectRoot, homeDirectoryPath: homeDirectoryPath)
        return workspaces.first {
            TasksConfigFile.normalizedPath($0.path, homeDirectoryPath: homeDirectoryPath) == target
        }
    }

    /// The skill a task's first message names: the project's own, else
    /// `[defaults]`.
    public func startSkill(forProjectRoot projectRoot: String, homeDirectoryPath: String = NSHomeDirectory()) -> String? {
        workspace(forProjectRoot: projectRoot, homeDirectoryPath: homeDirectoryPath)?.startSkill ?? defaults.startSkill
    }

    /// The skill a release task's first message names: the project's own,
    /// else `[defaults]`.
    public func releaseSkill(forProjectRoot projectRoot: String, homeDirectoryPath: String = NSHomeDirectory()) -> String? {
        workspace(forProjectRoot: projectRoot, homeDirectoryPath: homeDirectoryPath)?.releaseSkill ?? defaults.releaseSkill
    }

    /// Whether Toastty can start a release for the project: it has a
    /// release skill or its own `release_prompt`.
    public func canRelease(projectRoot: String, homeDirectoryPath: String = NSHomeDirectory()) -> Bool {
        releaseSkill(forProjectRoot: projectRoot, homeDirectoryPath: homeDirectoryPath) != nil
            || workspace(forProjectRoot: projectRoot, homeDirectoryPath: homeDirectoryPath)?.releasePrompt != nil
    }
}

public enum TasksConfigFile {
    private static let configDirectoryName = ".toastty"
    private static let fileName = "tasks.toml"

    /// Like agents.toml, tasks.toml is written by the user and names their
    /// own profiles and scripts, so runtime-isolated dev runs read the same
    /// file.
    public static func fileURL(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(filePath: homeDirectoryPath)
            .appending(path: configDirectoryName, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    /// The parsed file, or `.empty` when there is no file.
    public static func load(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory()
    ) throws -> TasksConfig {
        let url = fileURL(homeDirectoryPath: homeDirectoryPath)
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try parse(contents: contents, homeDirectoryPath: homeDirectoryPath)
    }

    public static func parse(contents: String, homeDirectoryPath: String = NSHomeDirectory()) throws -> TasksConfig {
        try TasksConfigParser(homeDirectoryPath: homeDirectoryPath).parse(contents: contents)
    }

    /// An absolute path with `~` expanded and symbolic links resolved, for
    /// comparing project roots.
    public static func normalizedPath(_ path: String, homeDirectoryPath: String = NSHomeDirectory()) -> String {
        var expanded = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if expanded == "~" {
            expanded = homeDirectoryPath
        } else if expanded.hasPrefix("~/") {
            expanded = homeDirectoryPath + expanded.dropFirst()
        }
        return URL(filePath: expanded, directoryHint: .isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path(percentEncoded: false)
            .trimmingTrailingSlash()
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        guard count > 1, hasSuffix("/") else { return self }
        return String(dropLast())
    }
}

/// A parser for the small part of TOML that tasks.toml uses: tables with
/// plain or one quoted key part, and quoted, triple-quoted or whole-number
/// values. Every error names its line.
private struct TasksConfigParser {
    private enum Table: Hashable {
        case triage
        case defaults
        case quickEntry
        case coordinator
        case workspace(path: String)

        var name: String {
            switch self {
            case .triage: "[triage]"
            case .defaults: "[defaults]"
            case .quickEntry: "[quick_entry]"
            case .coordinator: "[coordinator]"
            case .workspace(let path): "[workspace.\"\(path)\"]"
            }
        }
    }

    private enum Value {
        case string(String)
        case integer(Int)
    }

    private typealias Entries = [String: (value: Value, line: Int)]

    private static let expectedTables = "[triage], [defaults], [quick_entry], [coordinator] or [workspace.\"<root directory>\"]"

    /// Tables and keys from an earlier draft of this file, with what
    /// replaced them.
    private static let replacedTables: [String: String] = [
        "create": "[create] was replaced by create_hook in a [workspace.\"<root directory>\"] table",
        "start": "[start] was replaced by start_skill in [defaults] or a [workspace.\"<root directory>\"] table",
    ]
    private static let replacedKeys: [String: String] = [
        "profile": "profile was replaced by command, the full command line Toastty runs for triage",
        "guidance": "guidance was renamed to guidelines",
        "timeout-seconds": "timeout-seconds was renamed to timeout_seconds",
        "script": "script was replaced by create_hook in a [workspace.\"<root directory>\"] table",
        "skill": "skill was replaced by start_skill",
    ]

    let homeDirectoryPath: String

    func parse(contents: String) throws -> TasksConfig {
        let lines = contents.components(separatedBy: .newlines)
        var values: [Table: Entries] = [:]
        var tableOrder: [(table: Table, line: Int)] = []
        var workspaceRoots: [String: Int] = [:]
        var currentTable: Table?

        var lineIndex = 0
        while lineIndex < lines.count {
            let lineNumber = lineIndex + 1
            let trimmedLine = Self.stripComment(from: lines[lineIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lineIndex += 1
            guard trimmedLine.isEmpty == false else { continue }

            if trimmedLine.hasPrefix("[") {
                let table = try Self.table(fromHeader: trimmedLine, line: lineNumber)
                guard values[table] == nil else {
                    throw TasksConfigParseError(line: lineNumber, message: "duplicate table \(table.name)")
                }
                if case .workspace(let path) = table {
                    let root = TasksConfigFile.normalizedPath(path, homeDirectoryPath: homeDirectoryPath)
                    if let earlierLine = workspaceRoots[root] {
                        throw TasksConfigParseError(
                            line: lineNumber,
                            message: "\(table.name) names the same directory as the table on line \(earlierLine)"
                        )
                    }
                    workspaceRoots[root] = lineNumber
                }
                values[table] = [:]
                tableOrder.append((table, lineNumber))
                currentTable = table
                continue
            }

            guard let equalsIndex = trimmedLine.firstIndex(of: "=") else {
                throw TasksConfigParseError(line: lineNumber, message: "expected key = value")
            }
            guard let table = currentTable else {
                throw TasksConfigParseError(line: lineNumber, message: "expected a \(Self.expectedTables) table before keys")
            }
            let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = trimmedLine[trimmedLine.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard values[table]?[key] == nil else {
                throw TasksConfigParseError(line: lineNumber, message: "\(table.name) has duplicate \(key)")
            }

            let value: Value
            if rawValue.hasPrefix("\"\"\"") {
                let parsed = try Self.multilineString(lines: lines, startIndex: lineIndex - 1, line: lineNumber)
                lineIndex = parsed.nextIndex
                value = .string(parsed.text)
            } else if rawValue.hasPrefix("\"") {
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(rawValue.utf8)) else {
                    throw TasksConfigParseError(line: lineNumber, message: "\(table.name) has an invalid string for \(key)")
                }
                value = .string(decoded)
            } else if rawValue.isEmpty == false,
                      rawValue.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "_") }),
                      let integer = Int(rawValue.replacingOccurrences(of: "_", with: "")) {
                value = .integer(integer)
            } else {
                throw TasksConfigParseError(
                    line: lineNumber,
                    message: "\(table.name) \(key) must be a quoted string or a whole number"
                )
            }
            values[table, default: [:]][key] = (value, lineNumber)
        }

        var config = TasksConfig()
        for (table, line) in tableOrder {
            let entries = values[table] ?? [:]
            switch table {
            case .triage:
                config.triage = try triage(entries, tableLine: line)
            case .defaults:
                config.defaults = try defaults(entries)
            case .quickEntry:
                config.quickEntry = try quickEntry(entries)
            case .coordinator:
                config.coordinator = try coordinator(entries)
            case .workspace(let path):
                config.workspaces.append(try workspace(path: path, entries))
            }
        }
        return config
    }

    // MARK: - Tables

    private func triage(_ entries: Entries, tableLine: Int) throws -> TasksConfig.Triage {
        let table = Table.triage
        try Self.rejectUnknownKeys(entries, table: table, allowed: ["command", "guidelines", "guidelines_file", "timeout_seconds"])
        let guidelines = try Self.text("guidelines", in: entries, table: table)
        let guidelinesFile = try Self.string("guidelines_file", in: entries, table: table)
        if guidelines != nil, guidelinesFile != nil, let line = entries["guidelines_file"]?.line {
            throw TasksConfigParseError(line: line, message: "[triage] sets both guidelines and guidelines_file; keep one")
        }
        var timeoutSeconds = TasksConfig.Triage.defaultTimeoutSeconds
        if let entry = entries["timeout_seconds"] {
            let range = TasksConfig.Triage.timeoutRange
            guard case .integer(let seconds) = entry.value, range.contains(seconds) else {
                throw TasksConfigParseError(
                    line: entry.line,
                    message: "[triage] timeout_seconds must be a whole number from \(range.lowerBound) to \(range.upperBound)"
                )
            }
            timeoutSeconds = seconds
        }
        return TasksConfig.Triage(
            command: try Self.string("command", in: entries, table: table),
            guidelines: guidelines,
            guidelinesFile: guidelinesFile,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func defaults(_ entries: Entries) throws -> TasksConfig.Defaults {
        let table = Table.defaults
        try Self.rejectUnknownKeys(
            entries,
            table: table,
            allowed: ["agent", "model", "effort", "merge", "merge_prompt", "start_skill", "merge_skill", "release_skill"]
        )
        return TasksConfig.Defaults(
            agent: try Self.selection("agent", in: entries, table: table, maximumLength: 64),
            model: try Self.selection("model", in: entries, table: table, maximumLength: RemoteSessionStartPolicy.maximumModelLength),
            effort: try Self.selection("effort", in: entries, table: table, maximumLength: RemoteSessionStartPolicy.maximumReasoningEffortLength),
            merge: try Self.mergeMode(in: entries, table: table),
            mergePrompt: try Self.text("merge_prompt", in: entries, table: table),
            startSkill: try Self.skill("start_skill", in: entries, table: table),
            mergeSkill: try Self.skill("merge_skill", in: entries, table: table),
            releaseSkill: try Self.skill("release_skill", in: entries, table: table)
        )
    }

    private func quickEntry(_ entries: Entries) throws -> TasksConfig.QuickEntry {
        let table = Table.quickEntry
        try Self.rejectUnknownKeys(entries, table: table, allowed: ["shortcut"])
        guard let entry = entries["shortcut"], let value = try Self.string("shortcut", in: entries, table: table) else {
            return TasksConfig.QuickEntry()
        }
        if value.lowercased() == "none" {
            return TasksConfig.QuickEntry(shortcut: nil)
        }
        do {
            return TasksConfig.QuickEntry(shortcut: try QuickEntryShortcut.parse(value))
        } catch {
            throw TasksConfigParseError(line: entry.line, message: "\(table.name) \(error.localizedDescription)")
        }
    }

    private func coordinator(_ entries: Entries) throws -> TasksConfig.Coordinator {
        let table = Table.coordinator
        try Self.rejectUnknownKeys(entries, table: table, allowed: ["agent", "model", "effort"])
        let agent = try Self.selection("agent", in: entries, table: table, maximumLength: 64)
        let model = try Self.selection("model", in: entries, table: table, maximumLength: RemoteSessionStartPolicy.maximumModelLength)
        let effort = try Self.selection("effort", in: entries, table: table, maximumLength: RemoteSessionStartPolicy.maximumReasoningEffortLength)
        guard agent?.lowercased() != "none" else {
            if let line = entries["model"]?.line ?? entries["effort"]?.line {
                throw TasksConfigParseError(line: line, message: "[coordinator] sets agent = \"none\", so it takes no model or effort")
            }
            return TasksConfig.Coordinator(agent: nil)
        }
        return TasksConfig.Coordinator(
            agent: agent ?? TasksConfig.Coordinator.defaultAgent,
            model: model,
            effort: effort
        )
    }

    private func workspace(path: String, _ entries: Entries) throws -> TasksConfig.Workspace {
        let table = Table.workspace(path: path)
        try Self.rejectUnknownKeys(
            entries,
            table: table,
            allowed: [
                "guidelines", "create_hook", "branch_prefix", "release_tags", "release_prompt", "merge", "merge_prompt",
                "start_skill", "merge_skill", "release_skill",
            ]
        )
        let branchPrefix = try Self.string("branch_prefix", in: entries, table: table)
        if let branchPrefix, TaskRecord.sanitizedSlug(branchPrefix) != branchPrefix, let line = entries["branch_prefix"]?.line {
            throw TasksConfigParseError(
                line: line,
                message: "\(table.name) branch_prefix must be lowercase letters, digits and hyphens"
            )
        }
        return TasksConfig.Workspace(
            path: path,
            guidelines: try Self.text("guidelines", in: entries, table: table),
            createHook: try Self.string("create_hook", in: entries, table: table),
            branchPrefix: branchPrefix,
            releaseTags: try Self.string("release_tags", in: entries, table: table),
            releasePrompt: try Self.text("release_prompt", in: entries, table: table),
            merge: try Self.mergeMode(in: entries, table: table),
            mergePrompt: try Self.text("merge_prompt", in: entries, table: table),
            startSkill: try Self.skill("start_skill", in: entries, table: table),
            mergeSkill: try Self.skill("merge_skill", in: entries, table: table),
            releaseSkill: try Self.skill("release_skill", in: entries, table: table)
        )
    }

    // MARK: - Headers

    private static func table(fromHeader header: String, line: Int) throws -> Table {
        guard header.hasSuffix("]"), header.hasPrefix("[[") == false else {
            throw TasksConfigParseError(line: line, message: "invalid table header")
        }
        let name = String(header.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        switch name {
        case "triage": return .triage
        case "defaults": return .defaults
        case "quick_entry": return .quickEntry
        case "coordinator": return .coordinator
        default: break
        }
        if let replacement = replacedTables[name] {
            throw TasksConfigParseError(line: line, message: replacement)
        }
        guard name.hasPrefix("workspace") else {
            throw TasksConfigParseError(line: line, message: "unknown table [\(name)]; expected \(expectedTables)")
        }
        let rest = name.dropFirst("workspace".count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("."),
              case let quoted = rest.dropFirst().trimmingCharacters(in: .whitespaces),
              quoted.hasPrefix("\""),
              let path = try? JSONDecoder().decode(String.self, from: Data(quoted.utf8)) else {
            throw TasksConfigParseError(
                line: line,
                message: "a workspace table names its root directory in quotes: [workspace.\"~/path/to/repo\"]"
            )
        }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.hasPrefix("/") || trimmedPath == "~" || trimmedPath.hasPrefix("~/") else {
            throw TasksConfigParseError(
                line: line,
                message: "[workspace.\"\(path)\"] must name an absolute directory or one that starts with ~/"
            )
        }
        return .workspace(path: trimmedPath)
    }

    // MARK: - Values

    private static func rejectUnknownKeys(_ entries: Entries, table: Table, allowed: Set<String>) throws {
        guard let unknown = entries
            .filter({ allowed.contains($0.key) == false })
            .min(by: { $0.value.line < $1.value.line }) else { return }
        if let replacement = replacedKeys[unknown.key] {
            throw TasksConfigParseError(line: unknown.value.line, message: "\(table.name) \(replacement)")
        }
        throw TasksConfigParseError(line: unknown.value.line, message: "\(table.name) contains unknown key '\(unknown.key)'")
    }

    /// A present one-line value, trimmed; `nil` when the key is absent. An
    /// empty value is an error, so a typo cannot silently turn a setting off.
    private static func string(_ key: String, in entries: Entries, table: Table) throws -> String? {
        guard let entry = entries[key], let raw = try rawString(key, in: entries, table: table) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains(where: \.isNewline) == false else {
            throw TasksConfigParseError(line: entry.line, message: "\(table.name) \(key) must be one line")
        }
        return value
    }

    /// A present value that may span lines, with its outer blank space
    /// removed.
    private static func text(_ key: String, in entries: Entries, table: Table) throws -> String? {
        try rawString(key, in: entries, table: table)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rawString(_ key: String, in entries: Entries, table: Table) throws -> String? {
        guard let entry = entries[key] else { return nil }
        guard case .string(let raw) = entry.value else {
            throw TasksConfigParseError(line: entry.line, message: "\(table.name) \(key) must be a quoted string")
        }
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TasksConfigParseError(line: entry.line, message: "\(table.name) \(key) is empty")
        }
        return raw
    }

    /// An agent, model or effort value that Toastty passes to a provider
    /// CLI as one argument.
    private static func selection(_ key: String, in entries: Entries, table: Table, maximumLength: Int) throws -> String? {
        guard let entry = entries[key], let value = try string(key, in: entries, table: table) else { return nil }
        guard RemoteSessionStartPolicy.isValidSelectionValue(value, maximumLength: maximumLength) else {
            throw TasksConfigParseError(
                line: entry.line,
                message: "\(table.name) \(key) must be one word with no spaces that does not start with a dash"
            )
        }
        return value
    }

    /// A skill name, which goes into a message as `Use the <name> skill.`
    private static func skill(_ key: String, in entries: Entries, table: Table) throws -> String? {
        guard let entry = entries[key], let value = try string(key, in: entries, table: table) else { return nil }
        guard value.contains(where: \.isWhitespace) == false else {
            throw TasksConfigParseError(line: entry.line, message: "\(table.name) \(key) must be a skill name with no spaces")
        }
        return value
    }

    private static func mergeMode(in entries: Entries, table: Table) throws -> TasksConfig.MergeMode? {
        guard let entry = entries["merge"], let value = try string("merge", in: entries, table: table) else { return nil }
        guard let mode = TasksConfig.MergeMode(rawValue: value) else {
            throw TasksConfigParseError(
                line: entry.line,
                message: "\(table.name) merge must be \"agent\" or \"direct\""
            )
        }
        return mode
    }

    /// A `"""` string that starts on `lines[startIndex]`. A `#` inside it is
    /// text, not a comment.
    private static func multilineString(
        lines: [String],
        startIndex: Int,
        line: Int
    ) throws -> (text: String, nextIndex: Int) {
        let rawLine = lines[startIndex]
        guard let openRange = rawLine.range(of: "\"\"\"") else {
            throw TasksConfigParseError(line: line, message: "invalid multiline string")
        }
        let afterOpen = String(rawLine[openRange.upperBound...])
        if let closeRange = afterOpen.range(of: "\"\"\"") {
            guard afterOpen[closeRange.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else {
                throw TasksConfigParseError(line: line, message: "unexpected text after closing \"\"\"")
            }
            return (String(afterOpen[..<closeRange.lowerBound]), startIndex + 1)
        }
        // As in TOML, a line break right after the opening quotes is not
        // part of the text.
        var bodyLines: [String] = afterOpen.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [afterOpen]
        var index = startIndex + 1
        while index < lines.count {
            let bodyLine = lines[index]
            index += 1
            if let closeRange = bodyLine.range(of: "\"\"\"") {
                guard bodyLine[closeRange.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw TasksConfigParseError(line: index, message: "unexpected text after closing \"\"\"")
                }
                let tail = String(bodyLine[..<closeRange.lowerBound])
                if tail.trimmingCharacters(in: .whitespaces).isEmpty == false {
                    bodyLines.append(tail)
                }
                return (bodyLines.joined(separator: "\n"), index)
            }
            bodyLines.append(bodyLine)
        }
        throw TasksConfigParseError(line: line, message: "unterminated multiline string")
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
