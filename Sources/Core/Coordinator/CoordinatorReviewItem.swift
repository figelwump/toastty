import Foundation

/// A durable review of one task, repository, pull request and exact head.
public struct CoordinatorReviewItem: Codable, Equatable, Identifiable, Sendable {
    public static let maximumTitleLength = 200
    public static let maximumPathLength = 4_096
    public static let maximumBaseRefNameLength = 256
    public static let maximumActionHistoryCount = 64
    public let id: UUID
    public var revision: Int
    public let taskID: UUID
    public var taskTitle: String
    public let projectRoot: String
    /// `<owner>/<repo>`, matching the canonical PR URL.
    public let repository: String
    public let pullRequestURL: String
    public let headSHA: String
    /// The PR destination branch. Historical records can omit it.
    public let baseRefName: String?
    public var brief: CoordinatorReviewBrief
    /// Set by the native user surface. Agent publications cannot replace it.
    public var priorityOverride: CoordinatorReviewBrief.Priority?
    public let createdAt: Date
    public var updatedAt: Date
    public var userAction: CoordinatorReviewAction?
    /// Prior intents, retained when the user replaces or clears the current one.
    public var actionHistory: [CoordinatorReviewAction]?
    public var observedOutcome: CoordinatorReviewObservedOutcome

    public init(
        id: UUID = UUID(), revision: Int = 1, taskID: UUID, taskTitle: String,
        projectRoot: String, repository: String, pullRequestURL: String, headSHA: String,
        baseRefName: String? = nil,
        brief: CoordinatorReviewBrief, createdAt: Date = Date(), updatedAt: Date? = nil,
        priorityOverride: CoordinatorReviewBrief.Priority? = nil,
        userAction: CoordinatorReviewAction? = nil,
        actionHistory: [CoordinatorReviewAction]? = nil,
        observedOutcome: CoordinatorReviewObservedOutcome = .init()
    ) {
        self.id = id
        self.revision = revision
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.projectRoot = projectRoot
        self.repository = repository
        self.pullRequestURL = pullRequestURL
        self.headSHA = headSHA
        self.baseRefName = baseRefName
        self.brief = brief
        self.priorityOverride = priorityOverride
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.userAction = userAction
        self.actionHistory = actionHistory
        self.observedOutcome = observedOutcome
    }

    public func validate() throws {
        guard revision > 0 else {
            throw CoordinatorReviewValidationError.invalidField("revision", "Revision must be positive.")
        }
        try CoordinatorReviewValidation.text(taskTitle, field: "taskTitle", maximum: Self.maximumTitleLength)
        try CoordinatorReviewValidation.text(projectRoot, field: "projectRoot", maximum: Self.maximumPathLength)
        guard projectRoot.hasPrefix("/"), !projectRoot.contains("\0") else {
            throw CoordinatorReviewValidationError.invalidField("projectRoot", "Use an absolute project path.")
        }
        guard let link = WorkspacePullRequestLink(annotationURL: pullRequestURL),
              let components = URLComponents(string: pullRequestURL),
              link.number > 0, link.url == pullRequestURL, link.repository == repository,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              repository.count <= 256, Self.isValidRepository(repository) else {
            throw CoordinatorReviewValidationError.invalidField("pullRequestURL", "Use the canonical GitHub PR URL and matching repository.")
        }
        guard Self.isValidCommitID(headSHA) else {
            throw CoordinatorReviewValidationError.invalidField("headSHA", "Use a full commit ID.")
        }
        if let baseRefName {
            try CoordinatorReviewValidation.text(baseRefName, field: "baseRefName", maximum: Self.maximumBaseRefNameLength)
            guard baseRefName.unicodeScalars.allSatisfy({
                !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
            }) else {
                throw CoordinatorReviewValidationError.invalidField("baseRefName", "The branch name cannot contain whitespace or control characters.")
            }
        }
        try brief.validate()
        try CoordinatorReviewValidation.date(createdAt, field: "createdAt")
        try CoordinatorReviewValidation.date(updatedAt, field: "updatedAt")
        guard updatedAt >= createdAt else {
            throw CoordinatorReviewValidationError.invalidField("updatedAt", "The update predates the review.")
        }
        let history = actionHistory ?? []
        guard history.count <= Self.maximumActionHistoryCount else {
            throw CoordinatorReviewValidationError.invalidField("actionHistory", "Too many prior user intents.")
        }
        var intentIDs: Set<UUID> = []
        for action in history + [userAction].compactMap({ $0 }) {
            try action.validate()
            guard action.approvedHeadSHA.lowercased() == headSHA.lowercased() else {
                throw CoordinatorReviewValidationError.invalidField("approvedHeadSHA", "The action must name the reviewed head.")
            }
            guard intentIDs.insert(action.intentID).inserted else {
                throw CoordinatorReviewValidationError.invalidField("actionHistory", "Duplicate user intent identity.")
            }
        }
        try observedOutcome.validate()
    }

    public static func isValidCommitID(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64)
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private static func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }
        }
    }
}

public enum CoordinatorReviewValidationError: Error, Equatable, LocalizedError {
    case invalidField(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidField(let field, let reason): "Invalid review field \(field): \(reason)"
        }
    }
}

enum CoordinatorReviewValidation {
    static func text(_ value: String, field: String, maximum: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximum, !value.contains("\0") else {
            throw CoordinatorReviewValidationError.invalidField(field, "Use nonempty text of at most \(maximum) characters.")
        }
    }

    static func date(_ value: Date, field: String) throws {
        guard value.timeIntervalSince1970.isFinite else {
            throw CoordinatorReviewValidationError.invalidField(field, "Use a finite timestamp.")
        }
    }
}
