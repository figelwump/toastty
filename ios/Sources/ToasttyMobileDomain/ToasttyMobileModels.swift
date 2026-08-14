import Foundation
import RemoteProtocol

public extension AgentKind {
    var displayName: String { rawValue }
}

public enum MobileSessionDisplayState: Equatable, Sendable {
    case known(RemoteSessionState)
    case unsupported(rawValue: String)

    public static let starting = Self.known(.starting)
    public static let working = Self.known(.working)
    public static let awaitingInput = Self.known(.awaitingInput)
    public static let ready = Self.known(.ready)
    public static let interrupted = Self.known(.interrupted)
    public static let ended = Self.known(.ended)
    public static let error = Self.known(.error)
    public static let offline = Self.known(.offline)

    public var bucket: MobileSessionBucket {
        switch self {
        case .known(let state):
            state.presentationStatusFallback.bucket
        case .unsupported:
            .idle
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .known(let state):
            state.presentationStatusFallback.rawValue
        case .unsupported(let rawValue):
            "unsupported state \(rawValue)"
        }
    }
}

/// The exact state Toastty presents for a session on the desktop. Unknown
/// additive values remain represented but intentionally do not acquire a
/// misleading mobile label or color.
public enum MobileSessionStatus: Equatable, Sendable {
    case known(RemoteSessionPresentationStatus)
    case unsupported(rawValue: String)

    public static let idle = Self.known(.idle)
    public static let working = Self.known(.working)
    public static let needsApproval = Self.known(.needsApproval)
    public static let ready = Self.known(.ready)
    public static let error = Self.known(.error)

    public var bucket: MobileSessionBucket {
        switch self {
        case .known(let status):
            status.bucket
        case .unsupported:
            .idle
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .known(let status):
            status.rawValue.replacingOccurrences(of: "_", with: " ")
        case .unsupported:
            "status unavailable"
        }
    }
}

public extension RemoteSessionState {
    /// Conservative presentation fallback for hosts that predate the exact
    /// `presentationStatus` summary field. At the state-only boundary,
    /// awaiting input maps to ready; the compatibility snapshot additionally
    /// uses authoritative pending-interaction availability when it exists.
    var presentationStatusFallback: RemoteSessionPresentationStatus {
        switch self {
        case .starting, .working:
            .working
        case .awaitingInput, .ready:
            .ready
        case .interrupted, .error:
            .error
        case .ended, .offline:
            .idle
        }
    }

    var bucket: MobileSessionBucket { presentationStatusFallback.bucket }
}

public extension RemoteSessionPresentationStatus {
    var bucket: MobileSessionBucket {
        switch self {
        case .ready: .ready
        case .working: .working
        case .needsApproval: .needsApproval
        case .error: .error
        case .idle: .idle
        }
    }
}

public enum MobileSessionBucket: String, CaseIterable, Equatable, Sendable {
    case error
    case ready
    case needsApproval = "needs approval"
    case working
    case idle

    public var sortOrder: Int {
        switch self {
        case .error: 0
        case .ready: 1
        case .needsApproval: 2
        case .working: 3
        case .idle: 4
        }
    }

    public var isVisible: Bool { self != .idle }

}

public enum MobileInputAvailability: Equatable, Sendable {
    case openPrompt
    case localDraft
    case pendingInteraction(preview: String?)
    case unavailable(reason: String)

    public var allowsReply: Bool {
        if case .openPrompt = self { return true }
        return false
    }

    public var inputReason: String {
        switch self {
        case .openPrompt:
            "Ready for your reply"
        case .localDraft:
            "Draft in progress on the Mac"
        case .pendingInteraction(let preview):
            preview ?? "Waiting for a response on the Mac"
        case .unavailable:
            "Input is not available from this device"
        }
    }

}

/// Server-relative activity age anchored to a local monotonic receipt time.
/// Device wall-clock changes therefore cannot make a conversation younger or
/// older after its snapshot has been accepted.
public struct MobileActivityAge: Equatable, Sendable {
    public let secondsAtReceipt: Int
    public let receivedAtMonotonicTime: TimeInterval

    public init(secondsAtReceipt: Int, receivedAtMonotonicTime: TimeInterval) {
        self.secondsAtReceipt = max(0, secondsAtReceipt)
        self.receivedAtMonotonicTime = receivedAtMonotonicTime.isFinite
            ? max(0, receivedAtMonotonicTime)
            : 0
    }

    public func label(atMonotonicTime now: TimeInterval) -> String {
        let finiteNow = now.isFinite ? now : receivedAtMonotonicTime
        let elapsed = max(0, Int(finiteNow - receivedAtMonotonicTime))
        let seconds = secondsAtReceipt + elapsed
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// Comparable recency key; the shared "now" term cancels out when two
    /// conversations are compared, so no clock read is needed. Smaller means
    /// more recent activity.
    var recencyRank: TimeInterval {
        TimeInterval(secondsAtReceipt) - receivedAtMonotonicTime
    }
}

public struct MobileConversation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public let workspaceTitle: String
    public let cwd: String?
    public let agent: AgentKind
    public let title: String
    public let state: MobileSessionStatus
    public let inputAvailability: MobileInputAvailability
    private let fixedAge: String
    public let activityAge: MobileActivityAge?
    public let lastActivity: String

    public var age: String {
        activityAge?.label(atMonotonicTime: ProcessInfo.processInfo.systemUptime) ?? fixedAge
    }

    public var displayAge: String {
        let compactAge = age.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compactAge.isEmpty else { return "" }
        return compactAge == "now" ? compactAge : "\(compactAge) ago"
    }

    /// Mirrors the desktop sidebar's semantic path abbreviation instead of
    /// relying on width-dependent middle truncation.
    public var abbreviatedCWD: String? {
        guard let cwd else { return nil }
        let withoutTrailingSlashes = cwd.reversed().drop(while: { $0 == "/" }).reversed()
        let trailingSlashTrimmed = withoutTrailingSlashes.isEmpty
            ? "/"
            : String(withoutTrailingSlashes)
        if !trailingSlashTrimmed.contains("/") {
            return trailingSlashTrimmed
        }
        let normalizedPath = (trailingSlashTrimmed as NSString).standardizingPath
        let path = normalizedPath as NSString
        let lastComponent = path.lastPathComponent
        if !lastComponent.isEmpty, lastComponent != "/", path.pathComponents.count > 1 {
            return ".../\(lastComponent)"
        }
        return path.abbreviatingWithTildeInPath
    }

    public init(
        id: UUID,
        workspaceID: UUID,
        workspaceTitle: String,
        cwd: String?,
        agent: AgentKind,
        title: String,
        state: MobileSessionStatus,
        inputAvailability: MobileInputAvailability,
        age: String,
        activityAge: MobileActivityAge? = nil,
        lastActivity: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.cwd = Self.nonemptyTrimmed(cwd)
        self.agent = agent
        self.title = title
        self.state = state
        self.inputAvailability = inputAvailability
        fixedAge = age
        self.activityAge = activityAge
        self.lastActivity = lastActivity
    }

    public init(
        id: UUID,
        workspaceID: UUID,
        workspaceTitle: String,
        cwd: String?,
        agent: AgentKind,
        title: String,
        state: RemoteSessionState,
        inputAvailability: MobileInputAvailability,
        age: String,
        activityAge: MobileActivityAge? = nil,
        lastActivity: String
    ) {
        self.init(
            id: id,
            workspaceID: workspaceID,
            workspaceTitle: workspaceTitle,
            cwd: cwd,
            agent: agent,
            title: title,
            state: .known(state.presentationStatusFallback),
            inputAvailability: inputAvailability,
            age: age,
            activityAge: activityAge,
            lastActivity: lastActivity
        )
    }

    public var accessibilitySummary: String {
        let facts: [String?] = [
            title,
            state.accessibilityLabel,
            lastActivity,
            workspaceTitle,
            agent.displayName,
            cwd,
            displayAge,
        ]
        return facts
            .compactMap(Self.nonemptyTrimmed)
            .joined(separator: ", ")
    }

    private static func nonemptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Most recent activity first; conversations without a live activity age
    /// sort last. Title and id tie-breaks keep the order stable across
    /// snapshots (and deterministic for fixtures, which carry no live age).
    static func isMoreRecent(_ lhs: MobileConversation, _ rhs: MobileConversation) -> Bool {
        if let comparison = compareRecency(lhs, rhs) { return comparison }
        if let titleOrder = deterministicStringOrder(lhs.title, rhs.title) { return titleOrder }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func isOrderedBeforeInActivity(
        _ lhs: MobileConversation,
        _ rhs: MobileConversation
    ) -> Bool {
        if lhs.state.activitySortOrder != rhs.state.activitySortOrder {
            return lhs.state.activitySortOrder < rhs.state.activitySortOrder
        }
        return isMoreRecent(lhs, rhs)
    }

    /// `nil` means equal/unknown recency and lets the caller apply its own
    /// deterministic tie-breaks.
    static func compareRecency(
        _ lhs: MobileConversation,
        _ rhs: MobileConversation
    ) -> Bool? {
        switch (lhs.activityAge, rhs.activityAge) {
        case (let left?, let right?) where left.recencyRank != right.recencyRank:
            return left.recencyRank < right.recencyRank
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return nil
        }
    }
}

private extension MobileSessionStatus {
    var activitySortOrder: Int {
        switch self {
        case .known(let status): status.bucket.sortOrder
        case .unsupported: MobileSessionBucket.idle.sortOrder + 1
        }
    }
}

/// Stable across user locales so snapshots do not visibly reshuffle when all
/// authoritative ordering facts tie.
private func deterministicStringOrder(_ lhs: String, _ rhs: String) -> Bool? {
    let locale = Locale(identifier: "en_US_POSIX")
    let leftFolded = lhs.folding(options: [.caseInsensitive], locale: locale)
    let rightFolded = rhs.folding(options: [.caseInsensitive], locale: locale)
    if leftFolded != rightFolded { return leftFolded < rightFolded }
    if lhs != rhs { return lhs < rhs }
    return nil
}

public struct MobileWorkspace: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let conversations: [MobileConversation]

    public init(id: UUID, title: String, conversations: [MobileConversation]) {
        self.id = id
        self.title = title
        self.conversations = conversations
    }

    public var sortedConversations: [MobileConversation] {
        conversations.sorted(by: MobileConversation.isOrderedBeforeInActivity)
    }

}

public struct MobileHomeSnapshot: Equatable, Sendable {
    public let hostName: String
    public let workspaces: [MobileWorkspace]
    public let activitySessions: [MobileConversation]
    public let rankedWorkspaces: [MobileWorkspace]

    public init(hostName: String, workspaces: [MobileWorkspace]) {
        self.hostName = hostName
        self.workspaces = workspaces
        activitySessions = workspaces
            .flatMap(\.conversations)
            .sorted(by: MobileConversation.isOrderedBeforeInActivity)
        rankedWorkspaces = workspaces
            .map { workspace in
                MobileWorkspace(
                    id: workspace.id,
                    title: workspace.title,
                    conversations: workspace.sortedConversations
                )
            }
            .sorted(by: Self.isWorkspaceOrderedBefore)
    }

    private static func isWorkspaceOrderedBefore(
        _ lhs: MobileWorkspace,
        _ rhs: MobileWorkspace
    ) -> Bool {
        switch (lhs.conversations.first, rhs.conversations.first) {
        case (let left?, let right?):
            if left.state.activitySortOrder != right.state.activitySortOrder {
                return left.state.activitySortOrder < right.state.activitySortOrder
            }
            if let recencyOrder = MobileConversation.compareRecency(left, right) {
                return recencyOrder
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        if let titleOrder = deterministicStringOrder(lhs.title, rhs.title) { return titleOrder }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public enum MobileConnectionState: String, Equatable, Sendable {
    case live
    case reconnecting
    case offline
}
