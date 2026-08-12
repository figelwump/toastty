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
            state.bucket
        case .unsupported:
            .attention
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .known(let state):
            state.bucket.rawValue
        case .unsupported(let rawValue):
            "unsupported state \(rawValue)"
        }
    }
}

public extension RemoteSessionState {
    var bucket: MobileSessionBucket {
        switch self {
        case .awaitingInput: .needsYou
        case .starting, .working: .working
        case .ready: .ready
        case .interrupted, .error: .attention
        case .ended, .offline: .offline
        }
    }
}

public enum MobileSessionBucket: String, CaseIterable, Equatable, Sendable {
    case needsYou = "needs you"
    case working
    case ready
    case attention
    case offline

    public var sortOrder: Int {
        switch self {
        case .needsYou: 0
        case .working: 1
        case .attention: 2
        case .ready: 3
        case .offline: 4
        }
    }
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

    public var needsYouReason: String {
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

public struct MobileConversation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public let workspaceTitle: String
    public let workspacePath: String
    public let agent: AgentKind
    public let title: String
    public let state: MobileSessionDisplayState
    public let inputAvailability: MobileInputAvailability
    public let age: String
    public let lastActivity: String

    public init(
        id: UUID,
        workspaceID: UUID,
        workspaceTitle: String,
        workspacePath: String,
        agent: AgentKind,
        title: String,
        state: MobileSessionDisplayState,
        inputAvailability: MobileInputAvailability,
        age: String,
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
        self.age = age
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
        lastActivity: String
    ) {
        self.init(
            id: id,
            workspaceID: workspaceID,
            workspaceTitle: workspaceTitle,
            workspacePath: workspacePath,
            agent: agent,
            title: title,
            state: .known(state),
            inputAvailability: inputAvailability,
            age: age,
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

    public var needsYouCount: Int {
        conversations.count { $0.state == .known(.awaitingInput) }
    }

    public var workingCount: Int {
        conversations.count { $0.state.bucket == .working }
    }

    public var rollupLabel: String {
        if needsYouCount > 0 { return "\(needsYouCount) need you" }
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

    public var needsYou: [MobileConversation] {
        workspaces
            .flatMap(\.conversations)
            .filter { $0.state == .known(.awaitingInput) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

public enum MobileConnectionState: String, Equatable, Sendable {
    case live
    case reconnecting
    case offline
}
