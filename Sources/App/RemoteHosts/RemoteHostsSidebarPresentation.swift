import CoreState
import Foundation
import RemoteProtocol
import ToasttyMobileDomain

/// The rows one remote host contributes to the sidebar, built from its
/// session list. Kept apart from the view so tests can check order, labels,
/// and which rows can open a terminal.
struct RemoteHostSidebarPresentation: Equatable {
    struct Session: Identifiable, Equatable {
        let id: UUID
        let title: String
        let agentName: String
        let statusKind: SessionStatusKind?
        let detail: String
        /// Nil when a click opens a terminal; otherwise why it cannot.
        let attachUnavailableReason: String?

        var canAttach: Bool { attachUnavailableReason == nil }
    }

    struct Workspace: Identifiable, Equatable {
        let id: UUID
        let title: String
        let isSubspace: Bool
        let sessions: [Session]
    }

    let statusLabel: String?
    let isLive: Bool
    let offersPairing: Bool
    let workspaces: [Workspace]

    var sessionCount: Int { workspaces.reduce(0) { $0 + $1.sessions.count } }

    init(host: RemoteHostState) {
        statusLabel = Self.statusLabel(for: host.status)
        isLive = host.status == .live
        offersPairing = host.status == .notPaired

        guard let home = host.home, let snapshot = host.snapshot else {
            workspaces = []
            return
        }
        let summariesByID = Dictionary(
            snapshot.conversations.map { ($0.conversationID.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func sessions(in workspace: MobileWorkspace) -> [Session] {
            workspace.conversations.map { conversation in
                Session(
                    id: conversation.id,
                    title: conversation.title,
                    agentName: RemoteHostAgentName.displayName(for: conversation.agent),
                    statusKind: Self.statusKind(for: conversation.state),
                    detail: conversation.lastActivity,
                    attachUnavailableReason: Self.attachUnavailableReason(
                        host: host,
                        command: summariesByID[conversation.id]?.terminalAttachCommand
                    )
                )
            }
        }
        // Each top-level workspace is followed by its subspaces, as the local
        // sidebar nests them. A workspace with no session is left out: the
        // host also lists workspaces that only hold right-side panels.
        var rows: [Workspace] = []
        for workspace in home.topLevelWorkspaces {
            let subspaces = home.subspaceRows(of: workspace.id)
                .map { Workspace(id: $0.id, title: $0.workspace.title, isSubspace: true, sessions: sessions(in: $0.workspace)) }
                .filter { $0.sessions.isEmpty == false }
            let own = sessions(in: workspace)
            guard own.isEmpty == false || subspaces.isEmpty == false else { continue }
            rows.append(Workspace(id: workspace.id, title: workspace.title, isSubspace: false, sessions: own))
            rows.append(contentsOf: subspaces)
        }
        workspaces = rows
    }

    static func statusLabel(for status: RemoteHostConnectionStatus) -> String? {
        switch status {
        case .live: nil
        case .notPaired: "not paired"
        case .credentialUnavailable: "keychain locked"
        case .connecting: "connecting"
        case .reconnecting: "reconnecting"
        case .accessDenied: "access denied"
        case .incompatibleHost: "update needed"
        case .failed: "unreachable"
        }
    }

    private static func statusKind(for status: MobileSessionStatus) -> SessionStatusKind? {
        guard case .known(let known) = status else { return nil }
        switch known {
        case .idle: return .idle
        case .working: return .working
        case .needsApproval: return .needsApproval
        case .ready: return .ready
        case .error: return .error
        }
    }

    private static func attachUnavailableReason(host: RemoteHostState, command: String?) -> String? {
        guard host.status == .live else {
            return "Not connected to \(host.configuration.displayName) now."
        }
        guard host.supportsTerminalAttach else {
            return "Update Toastty on \(host.configuration.displayName) to attach terminals."
        }
        guard RemoteTerminalAttachCommand.normalizedWireValue(command) != nil else {
            return "No terminal to attach to. On \(host.configuration.displayName), the session's terminal profile needs a remoteAttachCommand."
        }
        return nil
    }
}
