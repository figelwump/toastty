import Foundation

/// One task: what the user or an agent asked for, the choices made for it,
/// and the task space it runs in. A record exists before its task space
/// (while setup runs or after it fails) and keeps existing after the task
/// space closes, so it is stored apart from the workspace layout.
public struct TaskRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The caller's key for this request. A second `task.create` with the
    /// same key returns this record instead of making another one.
    public var clientRequestID: String?
    public var createdAt: Date
    /// The task exactly as written. The agent always receives it unchanged.
    public var text: String
    public var attachments: [TaskAttachment]
    public var title: String
    /// Lowercase words joined by hyphens: the task space's name, and later
    /// its branch name.
    public var slug: String
    /// Set when the user or caller chose the title, so nothing renames it.
    public var titleSetByUser: Bool
    public var source: TaskSource
    /// The fields the caller set. Nothing Toastty decides overrides them.
    public var pinned: TaskFields
    /// The fields setup used: `pinned`, completed from `[defaults]`.
    public var resolved: TaskFields?
    /// The top-level workspace the task belongs to; its task space nests
    /// under it.
    public var workspaceID: UUID?
    /// The project's root directory, from that workspace. It is the key for
    /// `[workspace."…"]` sections in tasks.toml and never changes after it
    /// is set, so later moves of the work keep the same config.
    public var projectRoot: String?
    public var setup: TaskSetupState
    /// The steps setup finished, saved as each one happens.
    public var operation: TaskOperation
    /// The task space, once setup made it.
    public var taskSpaceWorkspaceID: UUID? {
        operation.taskSpace?.workspaceID
    }

    public init(
        id: UUID = UUID(),
        clientRequestID: String? = nil,
        createdAt: Date,
        text: String,
        attachments: [TaskAttachment] = [],
        title: String,
        slug: String,
        titleSetByUser: Bool = false,
        source: TaskSource,
        pinned: TaskFields = TaskFields(),
        resolved: TaskFields? = nil,
        workspaceID: UUID? = nil,
        projectRoot: String? = nil,
        setup: TaskSetupState = .settingUp,
        operation: TaskOperation = TaskOperation()
    ) {
        self.id = id
        self.clientRequestID = clientRequestID
        self.createdAt = createdAt
        self.text = text
        self.attachments = attachments
        self.title = title
        self.slug = slug
        self.titleSetByUser = titleSetByUser
        self.source = source
        self.pinned = pinned
        self.resolved = resolved
        self.workspaceID = workspaceID
        self.projectRoot = projectRoot
        self.setup = setup
        self.operation = operation
    }
}

/// The choices that place and start a task. Each one is optional: the
/// caller may set some, and setup fills the rest.
public struct TaskFields: Codable, Equatable, Sendable {
    public var workspaceID: UUID?
    /// An agent profile ID from agents.toml.
    public var agent: String?
    public var model: String?
    public var effort: String?
    /// The first prompt, sent before the task text.
    public var prompt: String?

    public init(
        workspaceID: UUID? = nil,
        agent: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        prompt: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.agent = agent
        self.model = model
        self.effort = effort
        self.prompt = prompt
    }
}

/// A file attached to a task. Toastty keeps its own copy, so the original
/// can move or disappear.
public struct TaskAttachment: Codable, Equatable, Sendable {
    /// The copy, as an absolute path.
    public var path: String
    /// The original file name.
    public var displayName: String

    public init(path: String, displayName: String) {
        self.path = path
        self.displayName = displayName
    }
}

/// Where a task came from.
public enum TaskSource: Codable, Equatable, Sendable {
    /// `toastty task create` from a shell that is not a managed agent.
    case cli
    /// A managed agent session, through the CLI.
    case agent(sessionID: String)
    /// The quick entry panel in the Mac app.
    case quickEntry
    /// Rebuilt from a task space whose record was missing.
    case recovered

    private enum Kind: String, Codable {
        case cli
        case agent
        case quickEntry
        case recovered
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case sessionID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown kind from a newer version reads as `.cli` rather than
        // dropping the whole record.
        switch (try? container.decode(Kind.self, forKey: .kind)) ?? .cli {
        case .cli:
            self = .cli
        case .agent:
            self = .agent(sessionID: try container.decode(String.self, forKey: .sessionID))
        case .quickEntry:
            self = .quickEntry
        case .recovered:
            self = .recovered
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cli:
            try container.encode(Kind.cli, forKey: .kind)
        case .agent(let sessionID):
            try container.encode(Kind.agent, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
        case .quickEntry:
            try container.encode(Kind.quickEntry, forKey: .kind)
        case .recovered:
            try container.encode(Kind.recovered, forKey: .kind)
        }
    }
}

/// How far setup got. A task is in the Inbox until it has started.
public enum TaskSetupState: Codable, Equatable, Sendable {
    case settingUp
    case setupFailed(reason: String)
    case started

    public var isStarted: Bool {
        self == .started
    }

    private enum Kind: String, Codable {
        case settingUp
        case setupFailed
        case started
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .settingUp:
            self = .settingUp
        case .setupFailed:
            self = .setupFailed(reason: try container.decode(String.self, forKey: .reason))
        case .started:
            self = .started
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .settingUp:
            try container.encode(Kind.settingUp, forKey: .kind)
        case .setupFailed(let reason):
            try container.encode(Kind.setupFailed, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .started:
            try container.encode(Kind.started, forKey: .kind)
        }
    }
}

/// The setup steps that changed something outside the record, with what
/// each one made. Saved to disk before and after each step, so a retry
/// after a failure or a crash continues from the last finished step
/// instead of starting over.
public struct TaskOperation: Codable, Equatable, Sendable {
    public struct TaskSpace: Codable, Equatable, Sendable {
        public var workspaceID: UUID
        /// The terminal the agent starts in.
        public var panelID: UUID

        public init(workspaceID: UUID, panelID: UUID) {
            self.workspaceID = workspaceID
            self.panelID = panelID
        }
    }

    public struct AgentLaunch: Codable, Equatable, Sendable {
        public var sessionID: String
        public var at: Date

        public init(sessionID: String, at: Date) {
            self.sessionID = sessionID
            self.at = at
        }
    }

    /// Saved before the task space is made, so a crash in between finds
    /// the IDs instead of making a second one.
    public var taskSpace: TaskSpace?
    /// Saved once the launch command reached the task space's terminal.
    public var agentLaunch: AgentLaunch?

    public init(taskSpace: TaskSpace? = nil, agentLaunch: AgentLaunch? = nil) {
        self.taskSpace = taskSpace
        self.agentLaunch = agentLaunch
    }
}

public extension TaskRecord {
    static let maximumTitleLength = 80
    static let maximumSlugLength = 40
    static let maximumAttachmentCount = 10
    static let maximumClientRequestIDLength = 128

    /// The first non-empty line of `text`, trimmed and cut to
    /// `maximumTitleLength` characters; `nil` when there is none.
    static func defaultTitle(for text: String) -> String? {
        let line = text
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.isEmpty == false }
        guard let line else { return nil }
        guard line.count > maximumTitleLength else { return line }
        return String(line.prefix(maximumTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Lowercase ASCII words joined by single hyphens, at most
    /// `maximumSlugLength` characters; `nil` when nothing is left.
    static func sanitizedSlug(_ raw: String) -> String? {
        var words: [String] = []
        var current = ""
        for scalar in raw.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if current.isEmpty == false {
                words.append(current)
                current = ""
            }
        }
        if current.isEmpty == false { words.append(current) }
        var slug = ""
        for word in words {
            let candidate = slug.isEmpty ? word : slug + "-" + word
            if candidate.count > maximumSlugLength {
                if slug.isEmpty { slug = String(word.prefix(maximumSlugLength)) }
                break
            }
            slug = candidate
        }
        return slug.isEmpty ? nil : slug
    }

    /// `slug`, or `slug-2`, `slug-3`… when it is taken.
    static func uniqueSlug(_ slug: String, taken: Set<String>) -> String {
        guard taken.contains(slug) else { return slug }
        var number = 2
        while true {
            let suffix = "-\(number)"
            // A cut that ends on a hyphen would give "--2", which is not a slug.
            var stem = slug.prefix(maximumSlugLength - suffix.count)
            while stem.hasSuffix("-") { stem = stem.dropLast() }
            let candidate = String(stem) + suffix
            if taken.contains(candidate) == false { return candidate }
            number += 1
        }
    }
}
