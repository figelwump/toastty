import Foundation
import RemoteProtocol

/// What placement may choose from, gathered by the app at one instant.
public struct TaskPlacementContext: Equatable, Sendable {
    public struct Workspace: Equatable, Sendable {
        public var id: UUID
        public var title: String
        /// Where a task space under it would start without a create script.
        /// `nil` when no terminal in it has a known, existing directory.
        public var directory: String?
        public var isTopLevel: Bool
        /// Titles of its current task spaces, newest last.
        public var taskSpaceTitles: [String]

        public init(id: UUID, title: String, directory: String?, isTopLevel: Bool, taskSpaceTitles: [String] = []) {
            self.id = id
            self.title = title
            self.directory = directory
            self.isTopLevel = isTopLevel
            self.taskSpaceTitles = taskSpaceTitles
        }
    }

    public struct Profile: Equatable, Sendable {
        public var id: String
        public var displayName: String
        public var agent: AgentKind
        /// Installed, and takes a first prompt.
        public var isAvailable: Bool
        public var supportsModel: Bool
        /// Empty when the agent has no effort setting.
        public var efforts: [String]

        public init(id: String, displayName: String, agent: AgentKind, isAvailable: Bool, supportsModel: Bool, efforts: [String]) {
            self.id = id
            self.displayName = displayName
            self.agent = agent
            self.isAvailable = isAvailable
            self.supportsModel = supportsModel
            self.efforts = efforts
        }
    }

    public var workspaces: [Workspace]
    public var profiles: [Profile]
    /// Slugs that other Inbox tasks hold for each parent workspace, so two
    /// tasks never get the same branch and folder name.
    public var reservedSlugs: [UUID: Set<String>]

    public init(workspaces: [Workspace], profiles: [Profile], reservedSlugs: [UUID: Set<String>] = [:]) {
        self.workspaces = workspaces
        self.profiles = profiles
        self.reservedSlugs = reservedSlugs
    }

    public func workspace(_ id: UUID?) -> Workspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    public func profile(_ id: String?) -> Profile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Workspaces a task can start in: top level, with a directory.
    public var placeableWorkspaces: [Workspace] {
        workspaces.filter { $0.isTopLevel && $0.directory != nil }
    }
}

public enum TaskPlacementProblem: Error, Equatable, Sendable {
    case noWorkspace
    case workspaceClosed
    case workspaceIsTaskSpace(title: String)
    case workspaceHasNoDirectory(title: String)
    case noAvailableAgent
    case agentUnavailable(profileID: String)
    case modelNotSupported(agent: String)
    case effortNotSupported(effort: String, agent: String)

    public var message: String {
        switch self {
        case .noWorkspace:
            "Pick a workspace to start this task."
        case .workspaceClosed:
            "That workspace is closed. Pick another one."
        case .workspaceIsTaskSpace(let title):
            "\(title) is a task space. Pick a top-level workspace."
        case .workspaceHasNoDirectory(let title):
            "\(title) has no directory yet. Open a terminal in it, or pick another workspace."
        case .noAvailableAgent:
            "No agent profile in agents.toml can start a task. Add one, then retry."
        case .agentUnavailable(let profileID):
            "The \(profileID) profile in agents.toml can't start. Check it, then retry."
        case .modelNotSupported(let agent):
            "\(agent) does not take a model choice."
        case .effortNotSupported(let effort, let agent):
            "\(agent) does not take effort \"\(effort)\"."
        }
    }
}

public enum TaskPlacement {
    public static let branchPrefixes = ["feat", "fix", "debug", "refactor", "test", "docs", "chore"]
    public static let defaultBranchPrefix = "feat"
    public static let maximumSlugLength = 40
    public static let maximumReasonLength = 300

    /// Lowercase ASCII words joined by single hyphens, at most 40
    /// characters; `nil` when nothing is left.
    public static func sanitizedSlug(_ raw: String) -> String? {
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
    public static func uniqueSlug(_ slug: String, taken: Set<String>) -> String {
        guard taken.contains(slug) else { return slug }
        var number = 2
        while true {
            let suffix = "-\(number)"
            // A cut that ends on a hyphen would give "--2", which is not a
            // slug and would not match itself once it is a task-space title.
            var stem = slug.prefix(maximumSlugLength - suffix.count)
            while stem.hasSuffix("-") { stem = stem.dropLast() }
            let candidate = String(stem) + suffix
            if taken.contains(candidate) == false { return candidate }
            number += 1
        }
    }

    /// One trimmed line of at most `maximumTitleLength` characters.
    public static func cleanedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let title = TaskInboxItem.defaultTitle(for: raw)
        return title == "Untitled task" ? nil : title
    }

    /// The triage answer with every field that fails a check dropped.
    public static func suggestion(from answer: TaskTriageAnswer, context: TaskPlacementContext) -> TaskInboxItem.Suggestion {
        let workspace = UUID(uuidString: answer.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { context.workspace($0) }
            .flatMap { $0.isTopLevel && $0.directory != nil ? $0 : nil }
        let profile = context.profile(answer.profileID).flatMap { $0.isAvailable ? $0 : nil }
        let model = answer.model.flatMap { model -> String? in
            guard let profile, profile.supportsModel,
                  RemoteSessionStartPolicy.isValidSelectionValue(model, maximumLength: RemoteSessionStartPolicy.maximumModelLength)
            else { return nil }
            return model
        }
        let effort = answer.effort.flatMap { effort -> String? in
            guard let profile, profile.efforts.contains(effort) else { return nil }
            return effort
        }
        let reason = answer.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskInboxItem.Suggestion(
            workspaceID: workspace?.id,
            title: cleanedTitle(answer.title),
            slug: sanitizedSlug(answer.slug),
            branchPrefix: branchPrefixes.contains(answer.branchPrefix) ? answer.branchPrefix : nil,
            profileID: profile?.id,
            model: model,
            effort: effort,
            reason: reason.isEmpty ? nil : String(reason.prefix(maximumReasonLength))
        )
    }

    /// The placement setup will use. Pins win over the suggestion; a
    /// suggested model or effort applies only with the suggested agent.
    /// `workspaceID`, when given, is the user's own pick and wins over all.
    public static func plan(
        for item: TaskInboxItem,
        workspaceID chosenWorkspaceID: UUID? = nil,
        context: TaskPlacementContext
    ) -> Result<TaskInboxItem.Plan, TaskPlacementProblem> {
        let suggestion = item.suggestion
        guard let workspaceID = chosenWorkspaceID ?? item.pins.workspaceID ?? suggestion?.workspaceID else {
            return .failure(.noWorkspace)
        }
        guard let workspace = context.workspace(workspaceID) else { return .failure(.workspaceClosed) }
        guard workspace.isTopLevel else { return .failure(.workspaceIsTaskSpace(title: workspace.title)) }
        guard workspace.directory != nil else { return .failure(.workspaceHasNoDirectory(title: workspace.title)) }

        let profile: TaskPlacementContext.Profile
        if let pinned = item.pins.profileID {
            guard let match = context.profile(pinned), match.isAvailable else {
                return .failure(.agentUnavailable(profileID: pinned))
            }
            profile = match
        } else if let suggested = context.profile(suggestion?.profileID), suggested.isAvailable {
            profile = suggested
        } else if let first = context.profiles.first(where: \.isAvailable) {
            profile = first
        } else {
            return .failure(.noAvailableAgent)
        }
        let followsSuggestion = profile.id == suggestion?.profileID

        let model = item.pins.model ?? (followsSuggestion ? suggestion?.model : nil)
        if model != nil, profile.supportsModel == false {
            return .failure(.modelNotSupported(agent: profile.displayName))
        }
        let effort = item.pins.effort ?? (followsSuggestion ? suggestion?.effort : nil)
        if let effort, profile.efforts.contains(effort) == false {
            return .failure(.effortNotSupported(effort: effort, agent: profile.displayName))
        }

        let title = suggestion?.title ?? TaskInboxItem.defaultTitle(for: item.text)
        let baseSlug = suggestion?.slug ?? sanitizedSlug(title) ?? "task"
        let taken = Set(workspace.taskSpaceTitles.compactMap { sanitizedSlug($0) })
            .union(context.reservedSlugs[workspace.id] ?? [])
        return .success(TaskInboxItem.Plan(
            workspaceID: workspace.id,
            title: title,
            slug: uniqueSlug(baseSlug, taken: taken),
            branchPrefix: suggestion?.branchPrefix ?? defaultBranchPrefix,
            profileID: profile.id,
            model: model,
            effort: effort
        ))
    }
}
