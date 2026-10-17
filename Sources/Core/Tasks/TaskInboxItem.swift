import Foundation

/// One quick task in the Inbox: the user's request, what it is pinned to,
/// and how far placement and setup got. An item leaves the Inbox when its
/// agent starts.
public struct TaskInboxItem: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Equatable, Sendable {
        /// Waiting for, or in, the triage call.
        case routing
        /// Triage could not place it; the user picks a workspace.
        case needsWorkspace
        /// The create script or the agent start is running.
        case settingUp
        /// The create script or the start failed; the user can retry.
        case setupFailed
    }

    public enum Source: String, Codable, Equatable, Sendable {
        case mac
        case cli
    }

    /// A file copied into Toastty's task attachment folder when the task
    /// was added.
    public struct Attachment: Codable, Equatable, Sendable {
        public var displayName: String
        public var path: String

        public init(displayName: String, path: String) {
            self.displayName = displayName
            self.path = path
        }
    }

    /// Choices the user fixed when adding the task. Triage fills only the
    /// rest.
    public struct Pins: Codable, Equatable, Sendable {
        public var workspaceID: UUID?
        public var profileID: String?
        public var model: String?
        public var effort: String?

        public init(workspaceID: UUID? = nil, profileID: String? = nil, model: String? = nil, effort: String? = nil) {
            self.workspaceID = workspaceID
            self.profileID = profileID
            self.model = model
            self.effort = effort
        }

        public var isEmpty: Bool {
            workspaceID == nil && profileID == nil && model == nil && effort == nil
        }
    }

    /// What triage answered, kept so the user can see it and so placing
    /// the task by hand reuses its title, slug and agent. A field that
    /// failed Toastty's checks is dropped.
    public struct Suggestion: Codable, Equatable, Sendable {
        public var workspaceID: UUID?
        public var title: String?
        public var slug: String?
        public var branchPrefix: String?
        public var profileID: String?
        public var model: String?
        public var effort: String?
        public var reason: String?

        public init(
            workspaceID: UUID? = nil,
            title: String? = nil,
            slug: String? = nil,
            branchPrefix: String? = nil,
            profileID: String? = nil,
            model: String? = nil,
            effort: String? = nil,
            reason: String? = nil
        ) {
            self.workspaceID = workspaceID
            self.title = title
            self.slug = slug
            self.branchPrefix = branchPrefix
            self.profileID = profileID
            self.model = model
            self.effort = effort
            self.reason = reason
        }
    }

    /// The checked placement that setup runs with.
    public struct Plan: Codable, Equatable, Sendable {
        public var workspaceID: UUID
        public var title: String
        public var slug: String
        public var branchPrefix: String
        public var profileID: String
        public var model: String?
        public var effort: String?

        public init(
            workspaceID: UUID,
            title: String,
            slug: String,
            branchPrefix: String,
            profileID: String,
            model: String?,
            effort: String?
        ) {
            self.workspaceID = workspaceID
            self.title = title
            self.slug = slug
            self.branchPrefix = branchPrefix
            self.profileID = profileID
            self.model = model
            self.effort = effort
        }
    }

    /// What the create script printed. Kept so a retry after a failed start
    /// does not run the script again.
    public struct CreatedDirectory: Codable, Equatable, Sendable {
        public var directory: String
        public var branch: String?
        public var baseRef: String?

        public init(directory: String, branch: String? = nil, baseRef: String? = nil) {
            self.directory = directory
            self.branch = branch
            self.baseRef = baseRef
        }
    }

    /// The task space Toastty made for this task. Saved before the task
    /// space is created, so a retry or a restart reuses it instead of
    /// making a second one with a second agent.
    public struct TaskSpace: Codable, Equatable, Sendable {
        public var workspaceID: UUID
        public var panelID: UUID

        public init(workspaceID: UUID, panelID: UUID) {
            self.workspaceID = workspaceID
            self.panelID = panelID
        }
    }

    public let id: UUID
    public var text: String
    public var attachments: [Attachment]
    public var source: Source
    public var createdAt: Date
    public var pins: Pins
    public var phase: Phase
    public var suggestion: Suggestion?
    public var plan: Plan?
    /// Why the task needs the user, for `needsWorkspace` and `setupFailed`.
    public var problem: String?
    public var createdDirectory: CreatedDirectory?
    public var taskSpace: TaskSpace?

    public init(
        id: UUID = UUID(),
        text: String,
        attachments: [Attachment] = [],
        source: Source,
        createdAt: Date,
        pins: Pins = Pins(),
        phase: Phase = .routing,
        suggestion: Suggestion? = nil,
        plan: Plan? = nil,
        problem: String? = nil,
        createdDirectory: CreatedDirectory? = nil,
        taskSpace: TaskSpace? = nil
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.source = source
        self.createdAt = createdAt
        self.pins = pins
        self.phase = phase
        self.suggestion = suggestion
        self.plan = plan
        self.problem = problem
        self.createdDirectory = createdDirectory
        self.taskSpace = taskSpace
    }

    public static let maximumTextLength = 32 * 1024
    public static let maximumTitleLength = 60

    /// The name the Inbox shows: the planned or suggested title, else the
    /// first line of the text.
    public var displayTitle: String {
        plan?.title ?? suggestion?.title ?? Self.defaultTitle(for: text)
    }

    public static func defaultTitle(for text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.isEmpty == false } ?? ""
        guard firstLine.isEmpty == false else { return "Untitled task" }
        guard firstLine.count > maximumTitleLength else { return firstLine }
        return String(firstLine.prefix(maximumTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
