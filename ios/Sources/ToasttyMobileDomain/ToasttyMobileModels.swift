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
    case ready
    case working
    case needsApproval = "needs approval"
    case error
    case idle

    public var sortOrder: Int {
        switch self {
        case .ready: 0
        case .working: 1
        case .needsApproval: 2
        case .error: 3
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
        self.receivedAtMonotonicTime = receivedAtMonotonicTime
    }

    public func label(atMonotonicTime now: TimeInterval) -> String {
        let elapsed = max(0, Int(now - receivedAtMonotonicTime))
        let seconds = secondsAtReceipt + elapsed
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

public struct MobileConversation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public let workspaceTitle: String
    public let workspacePath: String
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

    public init(
        id: UUID,
        workspaceID: UUID,
        workspaceTitle: String,
        workspacePath: String,
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
        self.workspacePath = workspacePath
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
        workspacePath: String,
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
            workspacePath: workspacePath,
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
        "\(title), \(state.accessibilityLabel), \(workspaceTitle), \(age)"
    }
}

public struct MobileWorkspace: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let path: String
    public let conversations: [MobileConversation]

    public init(id: UUID, title: String, path: String, conversations: [MobileConversation]) {
        self.id = id
        self.title = title
        self.path = path
        self.conversations = conversations
    }

    public var sortedConversations: [MobileConversation] {
        conversations.sorted {
            if $0.state.bucket.sortOrder == $1.state.bucket.sortOrder {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return $0.state.bucket.sortOrder < $1.state.bucket.sortOrder
        }
    }

    public var readyCount: Int {
        conversations.count { $0.state == .ready }
    }

    public var needsApprovalCount: Int {
        conversations.count { $0.state == .needsApproval }
    }

    public var workingCount: Int {
        conversations.count { $0.state.bucket == .working }
    }

    public var rollupLabel: String {
        if readyCount > 0 { return "\(readyCount) ready" }
        if needsApprovalCount > 0 { return "\(needsApprovalCount) need approval" }
        if workingCount > 0 { return "\(workingCount) working" }
        return "quiet"
    }
}

public struct MobileHomeSnapshot: Equatable, Sendable {
    public let hostName: String
    public let workspaces: [MobileWorkspace]

    public init(hostName: String, workspaces: [MobileWorkspace]) {
        self.hostName = hostName
        self.workspaces = workspaces
    }

    public var ready: [MobileConversation] {
        workspaces
            .flatMap(\.conversations)
            .filter { $0.state == .ready }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public var needsApproval: [MobileConversation] {
        workspaces
            .flatMap(\.conversations)
            .filter { $0.state == .needsApproval }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

}

public enum MobileConnectionState: String, Equatable, Sendable {
    case live
    case reconnecting
    case offline
}
