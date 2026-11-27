import RemoteProtocol
import Foundation

public enum SessionStatusKind: String, Codable, Equatable, Sendable {
    case idle
    case working
    case needsApproval = "needs_approval"
    case ready
    case error
}

public struct SessionStatus: Codable, Equatable, Sendable {
    public var kind: SessionStatusKind
    public var summary: String
    public var detail: String?
    public var claudeFableQuota: ClaudeFableQuota?

    public init(
        kind: SessionStatusKind, summary: String, detail: String? = nil,
        claudeFableQuota: ClaudeFableQuota? = nil
    ) {
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.claudeFableQuota = claudeFableQuota
    }
}

public struct ClaudeFableQuota: Codable, Equatable, Sendable {
    public static let preferredModel = "claude-fable-5-2"
    public static let fallbackModel = "claude-opus-5-5"
    public static let fallbackEffort = "high"
    private static let rejection = "You've hit your Fable limit"

    public let nativeSessionID: UUID
    public let resetsAt: Date?

    public init(nativeSessionID: UUID, resetsAt: Date?) {
        self.nativeSessionID = nativeSessionID
        self.resetsAt = resetsAt
    }

    public static func isRejection(_ text: String?) -> Bool {
        guard let text else { return false }
        return text == rejection || text.hasPrefix(rejection + " · ")
    }

    public static func resetDate(from text: String?, at reportedAt: Date) -> Date? {
        guard let text, isRejection(text),
              let reset = text.components(separatedBy: " · ").dropFirst().first,
              reset.hasPrefix("resets ") else { return nil }
        let value = String(reset.dropFirst("resets ".count))
        if let date = ISO8601DateFormatter().date(from: value) {
            return date > reportedAt && date.timeIntervalSince(reportedAt) <= 7 * 86_400 ? date : nil
        }
        // The CLI shows an English date or time and, when supplied, an
        // IANA zone in parentheses. Treat unknown renderings as unknown.
        let pieces = value.components(separatedBy: " (")
        guard pieces.count == 1 || (pieces.count == 2 && value.hasSuffix(")")) else { return nil }
        let timeZone = pieces.count == 1 ? TimeZone.current
            : TimeZone(identifier: String(pieces[1].dropLast()))
        guard let timeZone else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        let formats = ["MMM d 'at' h:mma", "MMM d, h:mma", "EEE h:mma", "h:mma",
                       "MMM d 'at' HH:mm", "MMM d, HH:mm", "EEE HH:mm", "HH:mm"]
        for format in formats {
            formatter.dateFormat = format
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: reportedAt) else { continue }
                formatter.defaultDate = calendar.startOfDay(for: day)
                guard let candidate = formatter.date(from: pieces[0]),
                      formatter.string(from: candidate).lowercased() == pieces[0].lowercased().replacingOccurrences(of: " ", with: " "),
                      calendar.isDate(candidate, inSameDayAs: day),
                      candidate > reportedAt, candidate.timeIntervalSince(reportedAt) <= 7 * 86_400 else { continue }
                return candidate
            }
        }
        return nil
    }
}

public enum SessionStatusProjection: Equatable, Sendable {
    case none
    case waitingOnChildren(childCount: Int, pendingBackgroundTaskCount: Int)
    case resuming

    public var isWaitingOnChildren: Bool {
        if case .waitingOnChildren = self { return true }
        return false
    }
}

public enum SessionChildRowSource: Equatable, Sendable {
    case activity
    case session
}

public struct SessionChildRow: Equatable, Sendable {
    public var id: String
    public var source: SessionChildRowSource
    public var displayName: String
    public var context: String?
    public var executionProfile: SessionAgentExecutionProfile?
    public var startedAt: Date
    public var statusKind: SessionStatusKind?
    public var panelID: UUID?
    public var workspaceID: UUID?
    public var sessionID: String?

    public init(
        id: String,
        source: SessionChildRowSource,
        displayName: String,
        context: String? = nil,
        executionProfile: SessionAgentExecutionProfile? = nil,
        startedAt: Date,
        statusKind: SessionStatusKind? = nil,
        panelID: UUID? = nil,
        workspaceID: UUID? = nil,
        sessionID: String? = nil
    ) {
        self.id = id
        self.source = source
        self.displayName = displayName
        self.context = Self.normalizedOptionalText(context)
        self.executionProfile = executionProfile?.isEmpty == false ? executionProfile : nil
        self.startedAt = startedAt
        self.statusKind = statusKind
        self.panelID = panelID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }
}

public struct WorkspaceSessionStatus: Equatable, Sendable {
    public var sessionID: String
    public var panelID: UUID
    public var workspaceID: UUID
    public var parentSessionID: String?
    public var agent: AgentKind
    public var status: SessionStatus
    public var projection: SessionStatusProjection
    /// What the session waits on; present only while `projection` is
    /// `.waitingOnChildren`.
    public var waitingSummary: SessionWaitingSummary?
    public var children: [SessionChildRow]
    public var displayTitleOverride: String?
    public var providerSessionName: String?
    public var cwd: String?
    public var updatedAt: Date
    /// When the session last reported a status. Unlike `updatedAt`, file,
    /// panel, and background-activity changes leave it alone.
    public var statusUpdatedAt: Date?
    /// When the agent itself last reported a status; see
    /// `SessionRecord.agentStatusUpdatedAt`.
    public var agentStatusUpdatedAt: Date?
    /// Start of the current turn, present only while the session's reported
    /// status is `.working`. A projected working state (waiting on children,
    /// resuming) has no turn of its own and leaves this `nil`.
    public var turnStartedAt: Date?
    public var lastTurnDuration: TimeInterval?
    public var isActive: Bool
    public var scopedWorkspaceIDs: Set<UUID>?
    public var effectiveScopedWorkspaceIDs: Set<UUID>?

    public var isWorkspaceScoped: Bool {
        scopedWorkspaceIDs != nil
    }

    public init(
        sessionID: String,
        panelID: UUID,
        workspaceID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        parentSessionID: String? = nil,
        agent: AgentKind,
        status: SessionStatus,
        projection: SessionStatusProjection = .none,
        waitingSummary: SessionWaitingSummary? = nil,
        children: [SessionChildRow] = [],
        displayTitleOverride: String? = nil,
        providerSessionName: String? = nil,
        cwd: String?,
        updatedAt: Date,
        statusUpdatedAt: Date? = nil,
        agentStatusUpdatedAt: Date? = nil,
        turnStartedAt: Date? = nil,
        lastTurnDuration: TimeInterval? = nil,
        isActive: Bool,
        scopedWorkspaceIDs: Set<UUID>? = nil,
        effectiveScopedWorkspaceIDs: Set<UUID>? = nil
    ) {
        self.sessionID = sessionID
        self.panelID = panelID
        self.workspaceID = workspaceID
        self.parentSessionID = Self.normalizedOptionalText(parentSessionID)
        self.agent = agent
        self.status = status
        self.projection = projection
        self.waitingSummary = waitingSummary
        self.children = children
        self.displayTitleOverride = displayTitleOverride
        self.providerSessionName = Self.normalizedOptionalText(providerSessionName)
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.agentStatusUpdatedAt = agentStatusUpdatedAt
        self.turnStartedAt = turnStartedAt
        self.lastTurnDuration = lastTurnDuration
        self.isActive = isActive
        self.scopedWorkspaceIDs = scopedWorkspaceIDs
        self.effectiveScopedWorkspaceIDs = effectiveScopedWorkspaceIDs
    }

    /// A caller-supplied title wins over the provider's generated name, which
    /// in turn wins over the bare agent name.
    public var displayTitle: String {
        displayTitleOverride ?? providerSessionName ?? agent.displayName
    }

    /// The row's own name, absent for sub-agent threads, `codex exec` runs and
    /// sessions the provider has not named yet.
    public var sessionName: String? {
        displayTitleOverride ?? providerSessionName
    }
}

/// Summary of a workspace's live agent sessions, used for the sidebar/top-bar
/// status labels. Process-watch monitors are not counted as agents.
public struct WorkspaceAgentSummary: Equatable, Sendable {
    public var running: Int
    public var active: Int

    public init(running: Int, active: Int) {
        self.running = running
        self.active = active
    }

    public var hasRunning: Bool { running > 0 }
    public var hasActive: Bool { active > 0 }

    public static func make(
        from statuses: [WorkspaceSessionStatus],
        workspaceID: UUID? = nil
    ) -> WorkspaceAgentSummary {
        // `isActive` is session liveness, not the working/active status bucket.
        let agents = statuses.filter { $0.agent != .processWatch && $0.isActive }
        let nestedSessionChildren = statuses.flatMap(\.children).filter { child in
            guard child.source == .session else { return false }
            guard let workspaceID else { return true }
            return child.workspaceID == workspaceID
        }
        let active = agents.filter { $0.status.kind == .working }.count +
            nestedSessionChildren.filter { $0.statusKind == .working }.count
        return WorkspaceAgentSummary(
            running: agents.count + nestedSessionChildren.count,
            active: active
        )
    }
}

private extension SessionChildRow {
    static func normalizedOptionalText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

private extension WorkspaceSessionStatus {
    static func normalizedOptionalText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}
