import CoreState
import Foundation
import RemoteProtocol
import ToasttyMobileDomain

/// What `toastty remote attach` needs to run `ssh` for one remote session.
struct RemoteHostAttachTarget: Equatable, Sendable {
    let remoteID: String
    let displayName: String
    let sshDestination: String
    /// Host-supplied text. It goes to `ssh` as one argument and is never
    /// typed into, or read by, a shell on this Mac.
    let command: String
    let conversationTitle: String
}

enum RemoteHostAttachFailure: Error, Equatable, LocalizedError {
    case unknownRemote
    case notConnected
    case hostDoesNotSupportAttach
    case unknownConversation
    case noAttachCommand
    case terminalUnavailable

    var errorDescription: String? {
        switch self {
        case .unknownRemote:
            "This remote is not in remotes.toml."
        case .notConnected:
            "Toastty is not connected to this remote now."
        case .hostDoesNotSupportAttach:
            "The remote's Toastty does not offer terminal attach. Update Toastty on that Mac."
        case .unknownConversation:
            "The remote no longer lists this session."
        case .noAttachCommand:
            "The remote has no terminal to attach to for this session. Its terminal profile needs a remoteAttachCommand, and an agent must be running in it."
        case .terminalUnavailable:
            "Toastty could not open a terminal for this session."
        }
    }
}

/// Resolves an attach target for the automation socket's `remote.attach-target` query.
typealias RemoteHostAttachTargetProvider =
    @MainActor (_ remoteID: String, _ conversationID: UUID) -> Result<RemoteHostAttachTarget, RemoteHostAttachFailure>

enum RemoteHostAttach {
    /// Resolves the target from the host's current state. A list kept from an
    /// earlier connection does not count: the host must be connected now, so
    /// a revoked or unpaired remote yields no command.
    static func target(
        host: RemoteHostState?,
        conversationID: UUID
    ) -> Result<RemoteHostAttachTarget, RemoteHostAttachFailure> {
        guard let host else { return .failure(.unknownRemote) }
        guard host.status == .live, let snapshot = host.snapshot else { return .failure(.notConnected) }
        guard host.supportsTerminalAttach else { return .failure(.hostDoesNotSupportAttach) }
        guard let summary = snapshot.conversations.first(where: { $0.conversationID.rawValue == conversationID }) else {
            return .failure(.unknownConversation)
        }
        guard let command = RemoteTerminalAttachCommand.normalizedWireValue(summary.terminalAttachCommand) else {
            return .failure(.noAttachCommand)
        }
        return .success(RemoteHostAttachTarget(
            remoteID: host.configuration.id,
            displayName: host.configuration.displayName,
            sshDestination: host.configuration.sshDestination,
            command: command,
            conversationTitle: summary.title
        ))
    }

    /// The line typed into the new local terminal. It holds only the CLI
    /// path variable, a remote ID from `remotes.toml`, and a UUID, so it reads
    /// the same in zsh, bash, and fish. The CLI asks this app for the SSH
    /// destination and the host's command, then runs `ssh` itself.
    static func shellCommandLine(remoteID: String, conversationID: UUID) -> String? {
        guard RemoteHostsFile.isValidHostID(remoteID) else { return nil }
        return "\"$\(ToasttyLaunchContextEnvironment.cliPathKey)\" remote attach \(remoteID) \(conversationID.uuidString)"
    }
}
