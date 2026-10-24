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
    /// When Toastty first saw the task finished with its task space closed;
    /// its attached files go a week later. See `TaskAttachmentRetention`.
    public var attachmentsFinishedSeenAt: Date?
    /// When Toastty removed its copies of the attached files, a week after
    /// the task finished. `attachments` keeps their names.
    public var attachmentsRemovedAt: Date?
    public var title: String
    /// Lowercase words joined by hyphens: the task space's name, and later
    /// its branch name.
    public var slug: String
    /// Set when the user or caller chose the title, so nothing renames it.
    public var titleSetByUser: Bool
    public var source: TaskSource
    /// The fields the caller set. Nothing Toastty decides overrides them.
    public var pinned: TaskFields
    /// The fields setup used: `pinned`, completed by triage and from
    /// `[defaults]`.
    public var resolved: TaskFields?
    /// What happened to triage when it did not answer in full: why it
    /// failed, or which of its choices Toastty could not use.
    public var triageNote: String?
    /// The top-level workspace the task belongs to; its task space nests
    /// under it.
    public var workspaceID: UUID?
    /// The project's root directory, from that workspace. It is the key for
    /// `[workspace."…"]` sections in tasks.toml and never changes after it
    /// is set, so later moves of the work keep the same config.
    public var projectRoot: String?
    public var setup: TaskSetupState
    /// While the task waits for a workspace: the project that is not open
    /// which triage suggested. The picker chooses it first.
    public var suggestedWorkspace: TaskWorkspaceSuggestion?
    /// The task whose agent created this one, when an agent split its work.
    /// Shown as "started from"; it does not nest task spaces.
    public var parentTaskID: UUID?
    /// Set when the work moves, or starts, in its own git worktree.
    public var startWork: TaskStartWork?
    /// Set when the task's agent starts as a fork of the conversation of the
    /// session that created the task (`task create --fork`). That session
    /// keeps running.
    public var forkSource: TaskStartWork.Source?
    /// The steps setup and start-work finished, saved as each one happens.
    public var operation: TaskOperation
    /// This task's requests to be told when other tasks reach a condition.
    /// Optional so records saved before watches existed still load.
    public var watches: [TaskWatch]?
    /// The workspace scope of the session that created the task, saved
    /// when it was created; `nil` when that session was unscoped. The
    /// task's agent gets this scope, plus its task space, even when setup
    /// runs after the creator ended.
    public var creatorScope: Set<UUID>?
    /// The task's pull request, copied from the task space's `github-pr`
    /// annotation so it outlives the task space.
    public var pullRequestURL: String?
    /// Set by an agent whose work has no pull request, when it is ready for
    /// the user to look at.
    public var readyForReviewAt: Date?
    /// The newest review packet the task's agent published, and the
    /// worktree's commit then. See `TaskPacket`.
    public var packetVersion: Int?
    public var packetHeadCommit: String?
    /// When the pull request was seen merged, and the commit it made. The
    /// commit is what a release tag must contain for the task to ship.
    public var mergedAt: Date?
    public var mergeCommit: String?
    /// When a release tag first contained `mergeCommit`, and that tag.
    public var shippedAt: Date?
    public var releaseTag: String?
    /// Closed without finishing.
    public var archivedAt: Date?
    /// Finished by hand, for work that does not merge or ship.
    public var doneAt: Date?
    /// When the user accepted the pull request for merging: a Merge click,
    /// or the first `task.merge`. The merge itself may still be checked
    /// by the agent, or wait for GitHub's checks.
    public var mergeRequestedAt: Date?
    /// When the user cancelled a merge. A `task.merge` from the same agent
    /// turn is refused after it.
    public var mergeCancelledAt: Date?
    /// The steps that closed the task space and removed its worktree after
    /// a merge, an archive, or a release, and why they stopped if they did.
    public var cleanup: TaskCleanup?
    /// Set on a release task: the tasks it releases.
    public var release: TaskRelease?
    /// The task space, once setup made it.
    public var taskSpaceWorkspaceID: UUID? {
        operation.taskSpace?.workspaceID
    }
    /// The task's worktree, once `git worktree add` made it.
    public var worktree: TaskOperation.Worktree? {
        operation.worktree.flatMap { $0.added ? $0 : nil }
    }
    /// The agent session that works on the task now: the one that continues
    /// in the worktree after a move, else the one setup started.
    public var currentSessionID: String? {
        operation.worktreeSession?.sessionID ?? operation.agentLaunch?.sessionID
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
        parentTaskID: UUID? = nil,
        startWork: TaskStartWork? = nil,
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
        self.parentTaskID = parentTaskID
        self.startWork = startWork
        self.operation = operation
    }
}

/// What closing a task's task space and worktree got done. Each step is
/// saved as it finishes, so a retry skips what is done and a stop stays
/// visible after the task space closes.
public struct TaskCleanup: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// After the pull request merged.
        case merge
        /// Closing the task without merging.
        case archive
        /// After a release shipped.
        case release
    }

    public var kind: Kind
    /// What was done, in order, as the user reads it.
    public var stepsDone: [String]
    /// Why the cleanup stopped; `nil` while it runs and once it finished.
    public var problem: String?
    public var finishedAt: Date?
    /// What the user chose for an archive, so a retry does the same.
    public var archiveOptions: TaskArchiveOptions?

    public init(
        kind: Kind,
        stepsDone: [String] = [],
        problem: String? = nil,
        finishedAt: Date? = nil,
        archiveOptions: TaskArchiveOptions? = nil
    ) {
        self.kind = kind
        self.stepsDone = stepsDone
        self.problem = problem
        self.finishedAt = finishedAt
        self.archiveOptions = archiveOptions
    }
}

/// What an archive may do beyond closing the task space and removing a
/// clean worktree. Each is off unless the user chose it.
public struct TaskArchiveOptions: Codable, Equatable, Sendable {
    /// Close the pull request on GitHub. Its branch stays there either way.
    public var closePullRequest: Bool
    /// Delete the local branch even when some of its commits are on no
    /// remote branch, or remove a detached worktree whose commit is on no
    /// remote branch or tag.
    public var deleteUnpushedCommits: Bool
    /// Remove the worktree even with uncommitted changes.
    public var discardChanges: Bool

    public init(closePullRequest: Bool = false, deleteUnpushedCommits: Bool = false, discardChanges: Bool = false) {
        self.closePullRequest = closePullRequest
        self.deleteUnpushedCommits = deleteUnpushedCommits
        self.discardChanges = discardChanges
    }
}

/// What a release task releases. Its commit is the setup's pinned base.
public struct TaskRelease: Codable, Equatable, Sendable {
    /// The project's To ship tasks when the release started.
    public var childTaskIDs: [UUID]

    public init(childTaskIDs: [UUID]) {
        self.childTaskIDs = childTaskIDs
    }
}

/// A request to give a task its own git worktree, and how far it got.
///
/// Two callers make one. `task.start-work` moves a running task: Toastty
/// makes the worktree, forks the agent's conversation into a new terminal
/// there, and closes the old one. `task.create --start-work` makes the
/// worktree during setup, and the task's agent starts there fresh.
public struct TaskStartWork: Codable, Equatable, Sendable {
    /// The session whose conversation moves into the worktree, or that a
    /// new task's agent forks. `nil` when the task's agent starts fresh in
    /// the worktree.
    public struct Source: Codable, Equatable, Sendable {
        /// Updated when Toastty restores the session under a new ID after
        /// a relaunch.
        public var sessionID: String
        public var panelID: UUID
        /// An agent profile ID.
        public var agent: String
        /// The provider conversation, when known: how a session restored in
        /// the same pane is recognized as this one.
        public var conversationID: String?

        public init(sessionID: String, panelID: UUID, agent: String, conversationID: String? = nil) {
            self.sessionID = sessionID
            self.panelID = panelID
            self.agent = agent
            self.conversationID = conversationID
        }
    }

    /// The first part of the branch name; the slug follows it.
    public var branchPrefix: String
    /// What the caller asked to start from: a branch name on the remote,
    /// or a local commit. `nil` means the remote's default branch.
    public var base: String?
    public var source: Source?
    public var requestedAt: Date
    public var state: TaskStartWorkState
    /// A worktree on no branch, at the pinned commit: what a release task
    /// builds from.
    public var detached: Bool?

    public init(
        branchPrefix: String,
        base: String? = nil,
        source: Source? = nil,
        requestedAt: Date,
        state: TaskStartWorkState = .running,
        detached: Bool? = nil
    ) {
        self.branchPrefix = branchPrefix
        self.base = base
        self.source = source
        self.requestedAt = requestedAt
        self.state = state
        self.detached = detached
    }

    public static let defaultBranchPrefix = "task"
    public static let maximumBranchPrefixLength = 40

    /// Whether `prefix` can start a branch name: lowercase ASCII words,
    /// digits, hyphens and slashes, with no empty part.
    public static func isValidBranchPrefix(_ prefix: String) -> Bool {
        guard prefix.isEmpty == false, prefix.count <= maximumBranchPrefixLength else { return false }
        return prefix.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            TaskRecord.sanitizedSlug(String(part)) == String(part)
        }
    }
}

public enum TaskStartWorkState: Codable, Equatable, Sendable {
    case running
    case failed(reason: String)
    /// The agent works in the worktree.
    case finished

    private enum Kind: String, Codable {
        case running
        case failed
        case finished
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .running:
            self = .running
        case .failed:
            self = .failed(reason: try container.decode(String.self, forKey: .reason))
        case .finished:
            self = .finished
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .running:
            try container.encode(Kind.running, forKey: .kind)
        case .failed(let reason):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .finished:
            try container.encode(Kind.finished, forKey: .kind)
        }
    }
}

/// The choices that place and start a task. Each one is optional: the
/// caller may set some, and setup fills the rest.
/// A project that is not open, by its title and root directory.
public struct TaskWorkspaceSuggestion: Codable, Equatable, Sendable {
    public var title: String
    public var rootDirectory: String

    public init(title: String, rootDirectory: String) {
        self.title = title
        self.rootDirectory = rootDirectory
    }
}

public struct TaskFields: Codable, Equatable, Sendable {
    public var workspaceID: UUID?
    /// An agent profile ID from agents.toml.
    public var agent: String?
    public var model: String?
    public var effort: String?
    /// The first prompt, sent before the task text.
    public var prompt: String?
    /// A title and slug the caller chose. Triage does not replace them.
    public var title: String?
    public var slug: String?
    /// The skill the first message names before everything else:
    /// `start_skill`, or `release_skill` for a release.
    public var skill: String?

    public init(
        workspaceID: UUID? = nil,
        agent: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        prompt: String? = nil,
        title: String? = nil,
        slug: String? = nil,
        skill: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.agent = agent
        self.model = model
        self.effort = effort
        self.prompt = prompt
        self.title = title
        self.slug = slug
        self.skill = skill
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
    /// Made for a task space that existed before it had a record, when the
    /// user or an agent chose to track it.
    case adopted

    private enum Kind: String, Codable {
        case cli
        case agent
        case quickEntry
        case recovered
        case adopted
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
        case .adopted:
            self = .adopted
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
        case .adopted:
            try container.encode(Kind.adopted, forKey: .kind)
        }
    }
}

/// How far setup got. A task is in the Inbox until it has started.
public enum TaskSetupState: Codable, Equatable, Sendable {
    /// Triage is choosing what the caller left out.
    case routing
    /// No open workspace was chosen; the user picks one.
    case needsWorkspace(reason: String)
    case settingUp
    case setupFailed(reason: String)
    case started

    public var isStarted: Bool {
        self == .started
    }

    private enum Kind: String, Codable {
        case routing
        case needsWorkspace
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
        case .routing:
            self = .routing
        case .needsWorkspace:
            self = .needsWorkspace(reason: try container.decode(String.self, forKey: .reason))
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
        case .routing:
            try container.encode(Kind.routing, forKey: .kind)
        case .needsWorkspace(let reason):
            try container.encode(Kind.needsWorkspace, forKey: .kind)
            try container.encode(reason, forKey: .reason)
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
        /// For an agent that forks its creator's conversation: the fork's
        /// own conversation, once the provider reported it. Its presence
        /// confirms the fork.
        public var forkConversationID: String?

        public init(sessionID: String, at: Date, forkConversationID: String? = nil) {
            self.sessionID = sessionID
            self.at = at
            self.forkConversationID = forkConversationID
        }
    }

    /// The commit a worktree starts from.
    public struct Base: Codable, Equatable, Sendable {
        public var sha: String
        /// Where the commit came from, such as `origin/main`, or the local
        /// commit or ref the caller named.
        public var ref: String
        /// Whether a fetch just returned `sha`. `false` with a `note` means
        /// the fetch failed and the last fetched commit was used.
        public var fetched: Bool
        public var note: String?

        public init(sha: String, ref: String, fetched: Bool, note: String? = nil) {
            self.sha = sha
            self.ref = ref
            self.fetched = fetched
            self.note = note
        }
    }

    public struct Worktree: Codable, Equatable, Sendable {
        public var path: String
        /// The branch the worktree is on. A detached worktree keeps the name
        /// it was given, but no branch of that name exists.
        public var branch: String
        /// The repository's main checkout, where git commands for the
        /// worktree run.
        public var checkoutRoot: String
        /// `false` while the names are reserved and `git worktree add` has
        /// not finished.
        public var added: Bool
        /// On no branch: `git worktree add --detach`.
        public var detached: Bool?

        public var isDetached: Bool { detached == true }

        public init(path: String, branch: String, checkoutRoot: String, added: Bool, detached: Bool? = nil) {
            self.path = path
            self.branch = branch
            self.checkoutRoot = checkoutRoot
            self.added = added
            self.detached = detached
        }
    }

    /// The agent session that continues a moved task in its worktree.
    public struct WorktreeSession: Codable, Equatable, Sendable {
        public var workspaceID: UUID
        public var panelID: UUID
        /// Saved once the launch command reached the terminal.
        public var sessionID: String?
        /// Whether the session forks the source's conversation, or starts
        /// fresh because the source's agent cannot be forked.
        public var forked: Bool
        /// The new conversation's own ID, once the provider reported it.
        /// Its presence confirms the fork.
        public var nativeConversationID: String?

        public init(
            workspaceID: UUID,
            panelID: UUID,
            sessionID: String? = nil,
            forked: Bool,
            nativeConversationID: String? = nil
        ) {
            self.workspaceID = workspaceID
            self.panelID = panelID
            self.sessionID = sessionID
            self.forked = forked
            self.nativeConversationID = nativeConversationID
        }
    }

    /// What happened to the session the work moved from.
    public enum SourceOutcome: Codable, Equatable, Sendable {
        case closed
        /// Its pane was the workspace's last, so its agent exited instead
        /// and the shell stays.
        case exited
        case kept(reason: String)

        private enum Kind: String, Codable {
            case closed
            case exited
            case kept
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case reason
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .closed:
                self = .closed
            case .exited:
                self = .exited
            case .kept:
                self = .kept(reason: try container.decode(String.self, forKey: .reason))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .closed:
                try container.encode(Kind.closed, forKey: .kind)
            case .exited:
                try container.encode(Kind.exited, forKey: .kind)
            case .kept(let reason):
                try container.encode(Kind.kept, forKey: .kind)
                try container.encode(reason, forKey: .reason)
            }
        }
    }

    /// Saved before the task space is made, so a crash in between finds
    /// the IDs instead of making a second one.
    public var taskSpace: TaskSpace?
    /// Saved once the launch command reached the task space's terminal.
    public var agentLaunch: AgentLaunch?
    /// Saved once the base commit is pinned, so a retry starts from the
    /// same commit.
    public var base: Base?
    /// Saved with `added == false` before `git worktree add` runs, then
    /// with `added == true` after it.
    public var worktree: Worktree?
    /// Set once `create_hook` succeeded, or when there is none.
    public var hookFinishedAt: Date?
    /// Saved before its terminal is made, like `taskSpace`.
    public var worktreeSession: WorktreeSession?
    public var sourceOutcome: SourceOutcome?

    public init(
        taskSpace: TaskSpace? = nil,
        agentLaunch: AgentLaunch? = nil,
        base: Base? = nil,
        worktree: Worktree? = nil,
        hookFinishedAt: Date? = nil,
        worktreeSession: WorktreeSession? = nil,
        sourceOutcome: SourceOutcome? = nil
    ) {
        self.taskSpace = taskSpace
        self.agentLaunch = agentLaunch
        self.base = base
        self.worktree = worktree
        self.hookFinishedAt = hookFinishedAt
        self.worktreeSession = worktreeSession
        self.sourceOutcome = sourceOutcome
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
