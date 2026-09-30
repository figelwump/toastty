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

    /// Whole seconds elapsed, advanced only from the monotonic anchor.
    public func seconds(atMonotonicTime now: TimeInterval) -> Int {
        let finiteNow = now.isFinite ? now : receivedAtMonotonicTime
        return secondsAtReceipt + max(0, Int(finiteNow - receivedAtMonotonicTime))
    }

    public func label(atMonotonicTime now: TimeInterval) -> String {
        let seconds = seconds(atMonotonicTime: now)
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
    /// When the conversation entered its current status bucket. Live snapshot
    /// mapping stamps this via `MobileStateTransitionTracker`; ordering falls
    /// back to `activityAge` when it is absent.
    public let stateEnteredAge: MobileActivityAge?
    public let lastActivity: String
    public let workspaceTabID: UUID?
    public let workspaceTabTitle: String?
    public let executionProfile: RemoteSessionExecutionProfile?
    /// The desktop's "Flag for Later" mark.
    public let isFlaggedForLater: Bool
    /// How long the turn a working session is in has run, anchored like
    /// `activityAge` so the phone's clock cannot stretch or shrink it.
    public let turnElapsed: MobileActivityAge?
    /// Length of the last finished turn, in seconds.
    public let lastTurnDuration: TimeInterval?

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
        stateEnteredAge: MobileActivityAge? = nil,
        lastActivity: String,
        executionProfile: RemoteSessionExecutionProfile? = nil,
        workspaceTabID: UUID? = nil,
        workspaceTabTitle: String? = nil,
        isFlaggedForLater: Bool = false,
        turnElapsed: MobileActivityAge? = nil,
        lastTurnDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.cwd = Self.nonemptyTrimmed(cwd)
        self.isFlaggedForLater = isFlaggedForLater
        self.turnElapsed = turnElapsed
        self.lastTurnDuration = lastTurnDuration.flatMap {
            $0.isFinite && $0 >= 0 ? min($0, Self.maximumDurationSeconds) : nil
        }
        self.agent = agent
        self.title = title
        self.state = state
        self.inputAvailability = inputAvailability
        fixedAge = age
        self.activityAge = activityAge
        self.stateEnteredAge = stateEnteredAge
        self.lastActivity = lastActivity
        self.workspaceTabID = workspaceTabID
        self.workspaceTabTitle = Self.nonemptyTrimmed(
            workspaceTabTitle?.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        )
        self.executionProfile = executionProfile.flatMap { $0.isEmpty ? nil : $0 }
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
        stateEnteredAge: MobileActivityAge? = nil,
        lastActivity: String,
        executionProfile: RemoteSessionExecutionProfile? = nil,
        workspaceTabID: UUID? = nil,
        workspaceTabTitle: String? = nil,
        isFlaggedForLater: Bool = false,
        turnElapsed: MobileActivityAge? = nil,
        lastTurnDuration: TimeInterval? = nil
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
            stateEnteredAge: stateEnteredAge,
            lastActivity: lastActivity,
            executionProfile: executionProfile,
            workspaceTabID: workspaceTabID,
            workspaceTabTitle: workspaceTabTitle,
            isFlaggedForLater: isFlaggedForLater,
            turnElapsed: turnElapsed,
            lastTurnDuration: lastTurnDuration
        )
    }

    /// The same conversation with its flag changed, for a change shown
    /// before the Mac confirms it.
    public func withFlaggedForLater(_ isFlaggedForLater: Bool) -> MobileConversation {
        MobileConversation(
            id: id, workspaceID: workspaceID, workspaceTitle: workspaceTitle, cwd: cwd, agent: agent,
            title: title, state: state, inputAvailability: inputAvailability, age: fixedAge,
            activityAge: activityAge, stateEnteredAge: stateEnteredAge, lastActivity: lastActivity,
            executionProfile: executionProfile, workspaceTabID: workspaceTabID,
            workspaceTabTitle: workspaceTabTitle, isFlaggedForLater: isFlaggedForLater,
            turnElapsed: turnElapsed, lastTurnDuration: lastTurnDuration
        )
    }

    /// The running turn's length as the desktop shows it: `45s`, `4m 12s`.
    public func elapsedTurnLabel(atMonotonicTime now: TimeInterval) -> String? {
        turnElapsed.map { Self.durationLabel(seconds: TimeInterval($0.seconds(atMonotonicTime: now))) }
    }

    public var lastTurnLabel: String? {
        lastTurnDuration.map(Self.durationLabel(seconds:))
    }

    /// Durations past this show as this; a garbled value must not trap the
    /// integer conversion.
    public static let maximumDurationSeconds: TimeInterval = 100 * 365 * 24 * 60 * 60

    public static func durationLabel(seconds: TimeInterval) -> String {
        let clamped = Int(seconds.isFinite ? min(max(0, seconds), maximumDurationSeconds) : 0)
        let minutes = clamped / 60
        let remaining = clamped % 60
        guard minutes > 0 else { return "\(remaining)s" }
        return String(format: "%dm %02ds", minutes, remaining)
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
            isFlaggedForLater ? "flagged for later" : nil,
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

    /// Anchor used for recency ordering. Preferring the bucket-entry moment
    /// over raw activity keeps working sessions from reshuffling on every
    /// streamed event: a conversation moves only when its status bucket
    /// changes, which is exactly when it needs attention.
    private var recencyAnchor: MobileActivityAge? { stateEnteredAge ?? activityAge }

    /// Most recent bucket entry first (falling back to activity age);
    /// conversations without either sort last. Title and id tie-breaks keep
    /// the order stable across snapshots (and deterministic for fixtures,
    /// which carry no live age).
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
        switch (lhs.recencyAnchor, rhs.recencyAnchor) {
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

extension MobileSessionStatus {
    var activitySortOrder: Int {
        switch self {
        case .known(let status): status.bucket.sortOrder
        case .unsupported: MobileSessionBucket.idle.sortOrder + 1
        }
    }
}

/// Stable across user locales so snapshots do not visibly reshuffle when all
/// authoritative ordering facts tie.
func deterministicStringOrder(_ lhs: String, _ rhs: String) -> Bool? {
    let locale = Locale(identifier: "en_US_POSIX")
    let leftFolded = lhs.folding(options: [.caseInsensitive], locale: locale)
    let rightFolded = rhs.folding(options: [.caseInsensitive], locale: locale)
    if leftFolded != rightFolded { return leftFolded < rightFolded }
    if lhs != rhs { return lhs < rhs }
    return nil
}

/// Remembers when each conversation entered its current status bucket so
/// streamed activity alone cannot reorder lists. Owned by whoever presents a
/// live snapshot stream and threaded through successive presentations; a
/// fresh tracker seeds every anchor from server-reported activity, so
/// one-shot presentations keep plain recency ordering.
public struct MobileStateTransitionTracker: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var bucketOrder: Int
        var enteredAge: MobileActivityAge
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    /// The age at which `id` entered its current bucket. First observation
    /// seeds from the server-reported activity age; a bucket change
    /// re-stamps the anchor to now; otherwise the stored anchor is returned
    /// unchanged so intra-bucket order stays stable across snapshots.
    public mutating func stateEnteredAge(
        for id: UUID,
        state: MobileSessionStatus,
        activityAge: MobileActivityAge,
        receivedAtMonotonicTime: TimeInterval
    ) -> MobileActivityAge {
        let bucketOrder = state.activitySortOrder
        if let entry = entries[id], entry.bucketOrder == bucketOrder {
            return entry.enteredAge
        }
        let enteredAge = entries[id] == nil
            ? activityAge
            : MobileActivityAge(
                secondsAtReceipt: 0,
                receivedAtMonotonicTime: receivedAtMonotonicTime
            )
        entries[id] = Entry(bucketOrder: bucketOrder, enteredAge: enteredAge)
        return enteredAge
    }

    /// Drops sessions absent from the latest snapshot so a later
    /// reappearance re-seeds from server-reported activity instead of a
    /// stale anchor.
    public mutating func retain(_ ids: some Sequence<UUID>) {
        let keep = Set(ids)
        entries = entries.filter { keep.contains($0.key) }
    }
}

public struct MobileWorkspace: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let conversations: [MobileConversation]
    public let panels: [RemoteWorkspacePanel]
    /// Desktop annotation chips, sorted by key by the host.
    public let annotations: [RemoteWorkspaceAnnotation]
    /// The workspace this one is nested under as a subspace, as the Mac
    /// reported it. `MobileHomeSnapshot` decides whether the link holds.
    public let parentWorkspaceID: UUID?
    /// The conversation that spawned this subspace, when the Mac lists it.
    public let spawningConversationID: UUID?
    public let primaryAnnotationKey: String?
    /// The subspace's done mark on the Mac.
    public let isDone: Bool

    public init(
        id: UUID,
        title: String,
        conversations: [MobileConversation],
        panels: [RemoteWorkspacePanel] = [],
        annotations: [RemoteWorkspaceAnnotation] = [],
        parentWorkspaceID: UUID? = nil,
        spawningConversationID: UUID? = nil,
        primaryAnnotationKey: String? = nil,
        isDone: Bool = false
    ) {
        self.id = id
        self.title = title
        self.conversations = conversations
        self.panels = panels
        self.annotations = annotations
        self.parentWorkspaceID = parentWorkspaceID
        self.spawningConversationID = spawningConversationID
        self.primaryAnnotationKey = primaryAnnotationKey
        self.isDone = isDone
    }

    public var sortedConversations: [MobileConversation] {
        conversations.sorted(by: MobileConversation.isOrderedBeforeInActivity)
    }

    /// The same workspace listing other conversations, for filtered and
    /// sorted views of it.
    public func withConversations(_ conversations: [MobileConversation]) -> MobileWorkspace {
        MobileWorkspace(
            id: id,
            title: title,
            conversations: conversations,
            panels: panels,
            annotations: annotations,
            parentWorkspaceID: parentWorkspaceID,
            spawningConversationID: spawningConversationID,
            primaryAnnotationKey: primaryAnnotationKey,
            isDone: isDone
        )
    }

    public func withDone(_ isDone: Bool) -> MobileWorkspace {
        MobileWorkspace(
            id: id,
            title: title,
            conversations: conversations,
            panels: panels,
            annotations: annotations,
            parentWorkspaceID: parentWorkspaceID,
            spawningConversationID: spawningConversationID,
            primaryAnnotationKey: primaryAnnotationKey,
            isDone: isDone
        )
    }
}

public struct MobileHomeSnapshot: Equatable, Sendable {
    public let hostName: String
    public let workspaces: [MobileWorkspace]
    public let activitySessions: [MobileConversation]
    /// Every workspace, subspaces included, most urgent first.
    public let rankedWorkspaces: [MobileWorkspace]
    /// Workspaces that are not nested under another, most urgent first. A
    /// workspace's urgency counts its subspaces' sessions, so a parent whose
    /// only activity is in a subspace still ranks by it.
    public let topLevelWorkspaces: [MobileWorkspace]
    private let subspaceRowsByParentID: [UUID: [MobileSubspaceRow]]

    public init(hostName: String, workspaces: [MobileWorkspace]) {
        self.hostName = hostName
        self.workspaces = workspaces
        activitySessions = workspaces
            .flatMap(\.conversations)
            .sorted(by: MobileConversation.isOrderedBeforeInActivity)
        let sorted = workspaces.map { $0.withConversations($0.sortedConversations) }
        rankedWorkspaces = sorted.sorted {
            Self.isOrderedBefore($0, $0.conversations.first, $1, $1.conversations.first)
        }

        // A link holds only when its parent is listed and is itself top
        // level. The Mac sends only such links; checking again keeps a
        // malformed snapshot from hiding a workspace. A parent whose own
        // link names a missing workspace counts as top level, and the
        // members of a cycle all stay top level.
        let workspacesByID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func listedParent(of workspace: MobileWorkspace) -> MobileWorkspace? {
            guard let parentID = workspace.parentWorkspaceID, parentID != workspace.id else { return nil }
            return workspacesByID[parentID]
        }
        func isSubspace(_ workspace: MobileWorkspace) -> Bool {
            guard let parent = listedParent(of: workspace) else { return false }
            return listedParent(of: parent) == nil
        }
        var rows: [UUID: [MobileSubspaceRow]] = [:]
        for workspace in sorted where isSubspace(workspace) {
            rows[workspace.parentWorkspaceID!, default: []].append(MobileSubspaceRow(workspace: workspace))
        }
        subspaceRowsByParentID = rows.mapValues { $0.sorted(by: MobileSubspaceRow.isOrderedBefore) }
        topLevelWorkspaces = sorted
            .filter { isSubspace($0) == false }
            .map { workspace -> (MobileWorkspace, MobileConversation?) in
                let members = workspace.conversations
                    + (rows[workspace.id] ?? []).flatMap(\.workspace.conversations)
                return (workspace, members.min(by: MobileConversation.isOrderedBeforeInActivity))
            }
            .sorted { Self.isOrderedBefore($0.0, $0.1, $1.0, $1.1) }
            .map(\.0)
    }

    /// Subspaces nested under `parentID`, in the desktop sidebar's order.
    public func subspaceRows(of parentID: UUID) -> [MobileSubspaceRow] {
        subspaceRowsByParentID[parentID] ?? []
    }

    /// The listed parent of a subspace, or `nil` for a top-level workspace.
    public func parent(of workspaceID: UUID) -> MobileWorkspace? {
        subspaceRowsByParentID.first { _, rows in
            rows.contains { $0.id == workspaceID }
        }.flatMap { parentID, _ in workspaces.first { $0.id == parentID } }
    }

    public func subspaceRow(id workspaceID: UUID) -> MobileSubspaceRow? {
        subspaceRowsByParentID.values.lazy.joined().first { $0.id == workspaceID }
    }

    /// Orders two workspaces by their most urgent member.
    private static func isOrderedBefore(
        _ lhs: MobileWorkspace,
        _ lhsLead: MobileConversation?,
        _ rhs: MobileWorkspace,
        _ rhsLead: MobileConversation?
    ) -> Bool {
        switch (lhsLead, rhsLead) {
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

/// A subspace's status on its row, in the order rows sort: the desktop
/// sidebar's order, where a finished turn leads because it is quickest to act
/// on and done tasks sink to the bottom.
public enum MobileSubspaceStatus: Int, Comparable, Equatable, Sendable {
    case ready
    case needsApproval
    case error
    case working
    case idle
    case done

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether the Active filter lists the row: something is happening in
    /// the subspace or it wants the user.
    public var isActive: Bool {
        switch self {
        case .ready, .needsApproval, .error, .working: true
        case .idle, .done: false
        }
    }

    /// The status mark is a checkbox only while the row is quiet. A spinner
    /// or an approval or error mark says something the box would hide.
    public var showsDoneToggle: Bool {
        switch self {
        case .idle, .ready, .done: true
        case .needsApproval, .error, .working: false
        }
    }

    /// Which status wins when a subspace has several sessions. Not the sort
    /// order: approval and error outrank a finished turn here.
    fileprivate var precedence: Int {
        switch self {
        case .needsApproval: 4
        case .error: 3
        case .ready: 2
        case .working: 1
        case .idle, .done: 0
        }
    }

    fileprivate init(_ bucket: MobileSessionBucket) {
        self = switch bucket {
        case .needsApproval: .needsApproval
        case .error: .error
        case .ready: .ready
        case .working: .working
        case .idle: .idle
        }
    }
}

/// One subspace as its parent lists it: the workspace, the single status its
/// sessions add up to, and the summary and chip that describe it.
public struct MobileSubspaceRow: Identifiable, Equatable, Sendable {
    public static let pullRequestAnnotationKey = "github-pr"

    public let workspace: MobileWorkspace
    public let status: MobileSubspaceStatus
    /// From the session that sets the status, so the mark and the text
    /// describe the same session.
    public let summary: String?

    public var id: UUID { workspace.id }

    public init(workspace: MobileWorkspace) {
        self.workspace = workspace
        let lead = workspace.conversations.max { lhs, rhs in
            let left = MobileSubspaceStatus(lhs.state.bucket).precedence
            let right = MobileSubspaceStatus(rhs.state.bucket).precedence
            if left != right { return left < right }
            // `max` keeps the later of equal elements, so order the more
            // recent one last.
            return MobileConversation.isMoreRecent(rhs, lhs)
        }
        let sessionStatus = lead.map { MobileSubspaceStatus($0.state.bucket) } ?? .idle
        // The done mark replaces a quiet status, including the unread turn
        // that set it. A session that is working or wants the user still
        // shows, since the user may need to act.
        status = workspace.isDone && sessionStatus.showsDoneToggle ? .done : sessionStatus
        summary = lead?.lastActivity
    }

    /// The one chip the row shows: the primary annotation, or the pull
    /// request when none is marked primary.
    public var chip: RemoteWorkspaceAnnotation? {
        for key in [workspace.primaryAnnotationKey, Self.pullRequestAnnotationKey] {
            if let key, let annotation = workspace.annotations.first(where: { $0.key == key }) {
                return annotation
            }
        }
        return nil
    }

    static func isOrderedBefore(_ lhs: MobileSubspaceRow, _ rhs: MobileSubspaceRow) -> Bool {
        if lhs.status != rhs.status { return lhs.status < rhs.status }
        if let titleOrder = deterministicStringOrder(lhs.workspace.title, rhs.workspace.title) {
            return titleOrder
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public enum MobileConnectionState: String, Equatable, Sendable {
    case live
    case reconnecting
    case offline
}
