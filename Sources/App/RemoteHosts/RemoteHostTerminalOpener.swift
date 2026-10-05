import CoreState
import Foundation

/// Opens a local terminal tab attached to one remote session.
///
/// Tabs for a remote go in an ordinary local workspace named after it. The
/// tab records nothing about the remote: after Toastty restarts it is a plain
/// local terminal, and it does not reconnect by itself.
@MainActor
final class RemoteHostTerminalOpener {
    private struct ConversationKey: Hashable {
        let remoteID: String
        let conversationID: UUID
    }

    private weak var store: AppStore?
    private let terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let hostsStore: RemoteHostsStore
    private let homeDirectoryPath: String
    private var panelIDByConversation: [ConversationKey: UUID] = [:]
    private var workspaceIDByRemoteID: [String: UUID] = [:]

    init(
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        hostsStore: RemoteHostsStore,
        homeDirectoryPath: String = NSHomeDirectory()
    ) {
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.hostsStore = hostsStore
        self.homeDirectoryPath = homeDirectoryPath
    }

    @discardableResult
    func open(
        remoteID: String,
        conversationID: UUID,
        windowID: UUID
    ) -> Result<Void, RemoteHostAttachFailure> {
        guard let store else { return .failure(.terminalUnavailable) }
        let key = ConversationKey(remoteID: remoteID, conversationID: conversationID)

        // A tab opened earlier for this session is shown again, whatever the
        // connection state: its SSH session does not depend on the gateway.
        if let panelID = panelIDByConversation[key] {
            // The tab may be in another window; this also brings that
            // window forward.
            if store.focusPanel(containing: panelID) {
                return .success(())
            }
            panelIDByConversation.removeValue(forKey: key)
        }

        let target: RemoteHostAttachTarget
        switch RemoteHostAttach.target(host: hostsStore.host(id: remoteID), conversationID: conversationID) {
        case .success(let value):
            target = value
        case .failure(let failure):
            return .failure(failure)
        }
        guard let commandLine = RemoteHostAttach.shellCommandLine(
            remoteID: remoteID,
            conversationID: conversationID
        ) else {
            return .failure(.unknownRemote)
        }

        let tabID = UUID()
        let panelID = UUID()
        terminalRuntimeRegistry.setPendingInitialInput(commandLine, forNewPanelID: panelID)
        let created: Bool
        if let workspaceID = existingWorkspaceID(for: target, windowID: windowID, state: store.state) {
            created = store.send(.createBackgroundTerminalTab(
                workspaceID: workspaceID, tabID: tabID, panelID: panelID, terminalCWD: homeDirectoryPath
            ))
            if created {
                _ = store.focusPanel(containing: panelID)
            }
        } else {
            let workspaceID = UUID()
            created = store.send(.createTerminalWorkspace(
                windowID: windowID,
                workspaceID: workspaceID,
                title: target.displayName,
                tabID: tabID,
                panelID: panelID,
                terminalCWD: homeDirectoryPath
            ))
            if created {
                workspaceIDByRemoteID[remoteID] = workspaceID
            }
        }
        guard created else {
            terminalRuntimeRegistry.discardPendingInitialInput(forPanelID: panelID)
            return .failure(.terminalUnavailable)
        }
        panelIDByConversation[key] = panelID
        return .success(())
    }

    /// The workspace this remote's tabs went to last, while it is still in the
    /// window. After a restart that record is gone, so a workspace with the
    /// remote's name is used again instead of adding a second one.
    private func existingWorkspaceID(
        for target: RemoteHostAttachTarget,
        windowID: UUID,
        state: AppState
    ) -> UUID? {
        guard let window = state.windows.first(where: { $0.id == windowID }) else { return nil }
        if let workspaceID = workspaceIDByRemoteID[target.remoteID], window.workspaceIDs.contains(workspaceID) {
            return workspaceID
        }
        let workspaceID = window.workspaceIDs.first { state.workspacesByID[$0]?.title == target.displayName }
        workspaceIDByRemoteID[target.remoteID] = workspaceID
        return workspaceID
    }
}
