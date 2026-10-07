import AppKit
import CoreState
import Foundation
import RemoteProtocol

/// What the Merge button and its shortcut do. The user picks it from the
/// button's menu; it is one app-wide preference, kept across launches.
enum WorkspaceMergeMode: String, CaseIterable, Sendable {
    /// After the pull request merges, Toastty closes the workspace, removes
    /// its worktree, and deletes its branches.
    case mergeAndCleanUp
    case mergeOnly

    var menuTitle: String {
        switch self {
        case .mergeAndCleanUp:
            return "Merge and Clean"
        case .mergeOnly:
            return "Merge Only"
        }
    }
}

/// What a subspace with a pull request shows for merging it: the Merge
/// button in the user's chosen mode, its in-progress form, the cleanup that
/// follows a Merge and Clean, or the done label. Top-level workspaces and
/// subspaces without a `github-pr` annotation show nothing.
enum WorkspaceMergePresentation: Equatable {
    case ready(pullRequest: String, mode: WorkspaceMergeMode)
    case merging(pullRequest: String)
    /// Done, with a cleanup waiting for the pull request to merge.
    case awaitingMerge(pullRequest: String)
    case cleaningUp(pullRequest: String)
    case cleanupFailed(pullRequest: String, reason: String)
    case done(pullRequest: String)
    /// Close Without Merging is running.
    case closing(pullRequest: String)

    /// The done mark is the only signal that a merge finished, and only a
    /// subspace can hold one, so a top-level workspace gets no button.
    static func make(
        workspace: WorkspaceState,
        request: WorkspaceMergeRequest?,
        cleanup: WorkspaceCleanupRequest? = nil,
        mode: WorkspaceMergeMode = .mergeAndCleanUp
    ) -> Self? {
        guard workspace.parentWorkspaceID != nil,
              let pullRequest = workspace.annotations[SidebarSubspacePresentation.annotationKeyPullRequest]?.text else {
            return nil
        }
        switch cleanup?.phase {
        case .closing:
            return .closing(pullRequest: pullRequest)
        case .cleaningUp:
            return .cleaningUp(pullRequest: pullRequest)
        case .failed(let reason):
            return .cleanupFailed(pullRequest: pullRequest, reason: reason)
        case .awaitingMerge where workspace.doneAt != nil:
            return .awaitingMerge(pullRequest: pullRequest)
        case .awaitingDone, .awaitingMerge, nil:
            break
        }
        if workspace.doneAt != nil {
            return .done(pullRequest: pullRequest)
        }
        if request != nil {
            return .merging(pullRequest: pullRequest)
        }
        return .ready(pullRequest: pullRequest, mode: mode)
    }

    var title: String {
        switch self {
        case .ready(let pullRequest, let mode):
            return Self.actionTitle(mode: mode, pullRequest: pullRequest)
        case .merging(let pullRequest):
            return "Merging \(pullRequest)…"
        case .awaitingMerge(let pullRequest):
            return "Cleans Up When \(pullRequest) Merges"
        case .cleaningUp(let pullRequest):
            return "Cleaning Up \(pullRequest)…"
        case .cleanupFailed(let pullRequest, _):
            return "Cleanup Stopped · \(pullRequest)"
        case .done(let pullRequest):
            return "Done · \(pullRequest)"
        case .closing(let pullRequest):
            return "Closing \(pullRequest)…"
        }
    }

    static let closeWithoutMergingTitle = "Close Without Merging…"

    static func actionTitle(mode: WorkspaceMergeMode, pullRequest: String) -> String {
        switch mode {
        case .mergeAndCleanUp:
            return "Merge & Clean \(pullRequest)"
        case .mergeOnly:
            return "Merge \(pullRequest)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var pullRequest: String {
        switch self {
        case .ready(let pullRequest, _),
             .merging(let pullRequest),
             .awaitingMerge(let pullRequest),
             .cleaningUp(let pullRequest),
             .cleanupFailed(let pullRequest, _),
             .done(let pullRequest),
             .closing(let pullRequest):
            return pullRequest
        }
    }

    /// Whether the user can still drop the pending cleanup.
    var canCancelCleanup: Bool {
        switch self {
        case .awaitingMerge, .cleanupFailed:
            return true
        default:
            return false
        }
    }
}

enum WorkspaceMergePrompt {
    /// The prompt the Merge button sends: the user's configured prompt, or
    /// the built-in one. The built-in prompt is plain language so it works in
    /// every agent without that agent's skill-invocation syntax, and it still
    /// reaches the done mark when the `worktree-done` skill is not installed.
    static func text(customPrompt: String?, pullRequest: String) -> String {
        if let customPrompt {
            return customPrompt
        }
        return "I reviewed this workspace's pull request (\(pullRequest)) and want it merged. "
            + "Use the worktree-done skill if you have it. Otherwise merge the pull request, "
            + "or turn on auto-merge if its checks are still running, then mark this workspace done by running: "
            + "\"$TOASTTY_CLI_PATH\" action run workspace.set-done"
    }

    /// The prompt is typed into the agent's terminal and submitted, so it has
    /// to stay on one line: a line break would submit it early.
    static func normalizedCustomPrompt(_ rawPrompt: String) -> String? {
        let singleLine = rawPrompt
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return singleLine.isEmpty ? nil : singleLine
    }
}

/// Runs a click on a workspace's Merge button: sends the merge prompt to an
/// agent session waiting for input in that workspace, or starts an agent
/// with it when none is running, and records the request so the button shows
/// progress.
@MainActor
struct WorkspaceMergeController {
    enum Problem: Equatable {
        /// No agent session in the workspace is waiting for input. The merge
        /// waits for the user rather than queueing, so they accept finished
        /// work and not a turn they have not seen end.
        case agentBusy
        case terminalUnavailable
        case noAgentProfile
        case noIdleTerminal
        /// The profile's command cannot take a first message, so a new agent
        /// cannot be handed the merge prompt.
        case profileCannotTakePrompt(profileID: String)
        case launchFailed(String)
        /// Merge and Clean needs the task's checkout, and no session or
        /// terminal in the workspace has a directory to find it from.
        case noCheckoutPath
        /// The `github-pr` annotation names no pull request number.
        case noPullRequestNumber
        /// Close Without Merging cannot start; the reason says why.
        case cannotClose(reason: String)
    }

    let store: AppStore
    let sessionRuntimeStore: SessionRuntimeStore
    var agentProfiles: @MainActor () -> [AgentProfile]
    /// Types the prompt into a panel's terminal and submits it.
    var sendPrompt: @MainActor (_ prompt: String, _ panelID: UUID) -> Bool
    var promptState: @MainActor (_ panelID: UUID) -> TerminalPromptState
    /// Starts an agent with the prompt as its first message and returns the
    /// new managed session's ID.
    var launchAgent: @MainActor (
        _ profileID: String,
        _ workspaceID: UUID,
        _ panelID: UUID,
        _ prompt: String
    ) async throws -> String
    /// Records or drops the cleanup that follows the merge.
    var requestCleanup: @MainActor (_ workspaceID: UUID, _ pullRequestNumber: Int, _ repoPath: String) -> Void
    var cancelCleanup: @MainActor (_ workspaceID: UUID) -> Void
    var presentProblem: @MainActor (_ problem: Problem, _ pullRequest: String) -> Void =
        WorkspaceMergeController.presentAlert
    /// Asks the user to confirm Close Without Merging.
    var confirmClose: @MainActor (_ pullRequest: String) -> Bool = WorkspaceMergeController.confirmCloseAlert
    var closeWithoutMerging: @MainActor (
        _ workspaceID: UUID,
        _ pullRequestNumber: Int,
        _ pullRequestURL: String,
        _ repoPath: String
    ) -> Void = { _, _, _, _ in }

    static func live(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        agentCatalogStore: AgentCatalogStore,
        agentLaunchService: AgentLaunchService
    ) -> Self {
        Self(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            agentProfiles: { agentCatalogStore.catalog.profiles },
            sendPrompt: { prompt, panelID in
                terminalRuntimeRegistry.sendText(
                    prompt,
                    submit: true,
                    panelID: panelID,
                    focusPolicy: .preserveFirstResponder
                )
            },
            promptState: { terminalRuntimeRegistry.promptState(panelID: $0) },
            launchAgent: { profileID, workspaceID, panelID, prompt in
                // The async launch prepares current skills first, so a merge
                // skill the prompt names is delivered to the new agent.
                try await agentLaunchService.launchAsync(
                    profileID: profileID,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    initialPrompt: prompt,
                    focusPolicy: .preserveFirstResponder
                ).sessionID
            },
            requestCleanup: { workspaceID, pullRequestNumber, repoPath in
                sessionRuntimeStore.workspaceCleanupCoordinator?.requestCleanup(
                    workspaceID: workspaceID,
                    pullRequestNumber: pullRequestNumber,
                    repoPath: repoPath
                )
            },
            cancelCleanup: { workspaceID in
                sessionRuntimeStore.workspaceCleanupCoordinator?.cancelCleanup(workspaceID: workspaceID)
            },
            closeWithoutMerging: { workspaceID, pullRequestNumber, pullRequestURL, repoPath in
                sessionRuntimeStore.workspaceCleanupCoordinator?.closeWithoutMerging(
                    workspaceID: workspaceID,
                    pullRequestNumber: pullRequestNumber,
                    pullRequestURL: pullRequestURL,
                    repoPath: repoPath
                )
            }
        )
    }

    /// Runs Close Without Merging after the user confirms it. It is offered
    /// only while the Merge button is ready, never through the shortcut.
    func requestClose(workspaceID: UUID) {
        guard let workspace = store.state.workspacesByID[workspaceID],
              case .ready(let pullRequest, _)? = WorkspaceMergePresentation.make(
                workspace: workspace,
                request: sessionRuntimeStore.workspaceMergeRequests[workspaceID],
                cleanup: sessionRuntimeStore.workspaceCleanupRequests[workspaceID]
              ) else {
            return
        }
        // The URL is required, not just a number: the script checks it names
        // a pull request in the checkout's repository before closing anything.
        let annotation = workspace.annotations[SidebarSubspacePresentation.annotationKeyPullRequest]
        guard let pullRequestURL = annotation?.url,
              let pullRequestNumber = WorkspaceCleanupRequest.pullRequestNumber(text: "", url: pullRequestURL) else {
            presentProblem(
                .cannotClose(reason: "The workspace's pull request label \"\(pullRequest)\" has no pull request URL. "
                    + "Set the github-pr annotation with the pull request's URL and try again."),
                pullRequest
            )
            return
        }
        guard let repoPath = checkoutPath(in: workspace) else {
            presentProblem(
                .cannotClose(reason: "Toastty could not find this workspace's checkout. Open a terminal in the worktree and try again."),
                pullRequest
            )
            return
        }
        guard confirmClose(pullRequest) else { return }
        closeWithoutMerging(workspaceID, pullRequestNumber, pullRequestURL, repoPath)
    }

    /// Returns the task that launches an agent when one has to start, so a
    /// caller can wait for the launch to settle; `nil` otherwise.
    @discardableResult
    func requestMerge(workspaceID: UUID, mode: WorkspaceMergeMode) -> Task<Void, Never>? {
        guard let workspace = store.state.workspacesByID[workspaceID],
              case .ready(let pullRequest, _)? = WorkspaceMergePresentation.make(
                workspace: workspace,
                request: sessionRuntimeStore.workspaceMergeRequests[workspaceID],
                cleanup: sessionRuntimeStore.workspaceCleanupRequests[workspaceID]
              ) else {
            return nil
        }
        // The cleanup is checked first, so a merge that could not be cleaned
        // up afterward does not start.
        var cleanup: (pullRequestNumber: Int, repoPath: String)?
        if mode == .mergeAndCleanUp {
            let annotation = workspace.annotations[SidebarSubspacePresentation.annotationKeyPullRequest]
            guard let pullRequestNumber = annotation.flatMap({
                WorkspaceCleanupRequest.pullRequestNumber(text: $0.text, url: $0.url)
            }) else {
                presentProblem(.noPullRequestNumber, pullRequest)
                return nil
            }
            guard let repoPath = checkoutPath(in: workspace) else {
                presentProblem(.noCheckoutPath, pullRequest)
                return nil
            }
            cleanup = (pullRequestNumber, repoPath)
        }
        let recordCleanup = {
            if let cleanup {
                requestCleanup(workspaceID, cleanup.pullRequestNumber, cleanup.repoPath)
            } else {
                cancelCleanup(workspaceID)
            }
        }
        let prompt = WorkspaceMergePrompt.text(
            customPrompt: store.pullRequestMergePrompt,
            pullRequest: pullRequest
        )

        switch sessionRuntimeStore.sessionRegistry.mergeTarget(workspaceID: workspaceID) {
        case .session(let session):
            // Typed into the agent's input as the user would type it, so any
            // text already sitting there is submitted with it.
            guard sendPrompt(prompt, session.panelID) else {
                presentProblem(.terminalUnavailable, pullRequest)
                return nil
            }
            sessionRuntimeStore.beginWorkspaceMergeRequest(workspaceID: workspaceID, sessionID: session.sessionID)
            recordCleanup()
            return nil

        case .busy:
            presentProblem(.agentBusy, pullRequest)
            return nil

        case .noSession(let lastAgent):
            let profiles = agentProfiles()
            guard let profile = profiles.first(where: { $0.id == lastAgent?.rawValue }) ?? profiles.first else {
                presentProblem(.noAgentProfile, pullRequest)
                return nil
            }
            guard let panelID = idleTerminalPanelID(in: workspace) else {
                presentProblem(.noIdleTerminal, pullRequest)
                return nil
            }
            // Recorded before the launch so the button shows progress and a
            // second click cannot start a second agent.
            sessionRuntimeStore.beginWorkspaceMergeRequest(workspaceID: workspaceID, sessionID: nil)
            return Task { @MainActor in
                do {
                    let sessionID = try await launchAgent(profile.id, workspaceID, panelID, prompt)
                    sessionRuntimeStore.beginWorkspaceMergeRequest(workspaceID: workspaceID, sessionID: sessionID)
                    recordCleanup()
                } catch {
                    sessionRuntimeStore.cancelWorkspaceMergeRequest(workspaceID: workspaceID)
                    if case AgentLaunchError.initialPromptUnsupported(let profileID) = error {
                        presentProblem(.profileCannotTakePrompt(profileID: profileID), pullRequest)
                    } else {
                        presentProblem(.launchFailed(error.localizedDescription), pullRequest)
                    }
                }
            }
        }
    }

    /// A directory inside the task's checkout: the most recent agent
    /// session's repository root or directory, else a terminal's directory.
    private func checkoutPath(in workspace: WorkspaceState) -> String? {
        let sessions = sessionRuntimeStore.sessionRegistry.sessionsByID.values
            .filter { $0.workspaceID == workspace.id }
            .sorted { $0.updatedAt > $1.updatedAt }
        for session in sessions {
            for path in [session.repoRoot, session.cwd] {
                if let path, path.isEmpty == false {
                    return path
                }
            }
        }
        var panelIDs: [UUID] = []
        if let focusedPanelID = workspace.focusedPanelID {
            panelIDs.append(focusedPanelID)
        }
        panelIDs.append(contentsOf: workspace.allPanelsByID.keys.sorted { $0.uuidString < $1.uuidString })
        for panelID in panelIDs {
            if case .terminal(let terminal)? = workspace.panelState(for: panelID), terminal.cwd.isEmpty == false {
                return terminal.cwd
            }
        }
        return nil
    }

    /// A terminal sitting at its shell prompt, where an agent can start. The
    /// focused panel wins, then tab and layout order.
    private func idleTerminalPanelID(in workspace: WorkspaceState) -> UUID? {
        var candidatePanelIDs: [UUID] = []
        if let focusedPanelID = workspace.focusedPanelID {
            candidatePanelIDs.append(focusedPanelID)
        }
        for tabID in workspace.tabIDs {
            guard let tab = workspace.tabsByID[tabID] else { continue }
            candidatePanelIDs.append(contentsOf: tab.layoutTree.allSlotInfos.map(\.panelID))
        }
        return candidatePanelIDs.first { panelID in
            guard case .terminal? = workspace.panelState(for: panelID) else { return false }
            return promptState(panelID).isIdleAtPrompt
        }
    }

    static func alertText(for problem: Problem, pullRequest: String) -> (title: String, message: String) {
        switch problem {
        case .agentBusy:
            return (
                "The Agent Is Busy",
                "Merge \(pullRequest) once the agent in this workspace has finished its turn and is waiting for input."
            )
        case .terminalUnavailable:
            return (
                "Unable to Reach the Agent",
                "Toastty could not send the merge request to the agent's terminal."
            )
        case .noAgentProfile:
            return (
                "No Agent to Run the Merge",
                "No agent session is running in this workspace, and no agent profiles are configured in agents.toml."
            )
        case .noIdleTerminal:
            return (
                "No Agent to Run the Merge",
                "No agent session is running in this workspace, and none of its terminals is at a prompt to start one in."
            )
        case .profileCannotTakePrompt(let profileID):
            return (
                "Unable to Start an Agent With the Merge Request",
                "No agent session is running in this workspace, and the '\(profileID)' profile cannot start with a first message. "
                    + "Start the agent in this workspace and click Merge again, or add "
                    + "initialPromptPlacement = \"trailing\" to the profile in agents.toml if its command accepts a prompt as its last argument."
            )
        case .launchFailed(let message):
            return ("Unable to Run Agent", message)
        case .noCheckoutPath:
            return (
                "Unable to Clean Up After the Merge",
                "Toastty could not find this workspace's checkout, so it could not clean up after merging \(pullRequest). "
                    + "Open a terminal in the worktree and try again, or choose Merge Only."
            )
        case .noPullRequestNumber:
            return (
                "Unable to Clean Up After the Merge",
                "The workspace's pull request label \"\(pullRequest)\" has no pull request number or URL. "
                    + "Choose Merge Only, or set the github-pr annotation with the pull request's URL."
            )
        case .cannotClose(let reason):
            return ("Unable to Close \(pullRequest)", reason)
        }
    }

    private static func confirmCloseAlert(pullRequest: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close \(pullRequest) Without Merging?"
        alert.informativeText = "Toastty closes the pull request on GitHub, closes this workspace and ends its "
            + "sessions, removes its worktree, and deletes the local branch. The branch stays on GitHub, "
            + "so you can reopen the pull request."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Pull Request")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func presentAlert(_ problem: Problem, pullRequest: String) {
        let text = alertText(for: problem, pullRequest: pullRequest)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
