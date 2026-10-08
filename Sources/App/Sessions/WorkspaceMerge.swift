import AppKit
import CoreState
import Foundation

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
/// subspaces whose `github-pr` annotation has no GitHub pull request URL show
/// nothing. The label comes from that URL, never from the annotation's text,
/// so it always names the pull request the button acts on.
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

    /// The done mark records a finished merge, and only a subspace can hold
    /// one, so a top-level workspace gets no button.
    static func make(
        workspace: WorkspaceState,
        request: WorkspaceMergeRequest?,
        mode: WorkspaceMergeMode = .mergeAndCleanUp
    ) -> Self? {
        guard workspace.parentWorkspaceID != nil,
              let link = pullRequestLink(in: workspace) else {
            return nil
        }
        let pullRequest = "PR #\(link.number)"
        switch request?.phase {
        case .merging:
            return .merging(pullRequest: pullRequest)
        case .closing:
            return .closing(pullRequest: pullRequest)
        case .cleaningUp:
            return .cleaningUp(pullRequest: pullRequest)
        case .failed(let reason):
            return .cleanupFailed(pullRequest: pullRequest, reason: reason)
        case .awaitingMerge where workspace.doneAt != nil,
             .awaitingChecks(_, thenCleanUp: true) where workspace.doneAt != nil:
            return .awaitingMerge(pullRequest: pullRequest)
        case .awaitingMerge, .awaitingChecks, nil:
            // A Merge Only that waits for checks shows as done: the user has
            // accepted the version, and Toastty merges it when it can.
            break
        }
        if workspace.doneAt != nil {
            return .done(pullRequest: pullRequest)
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

    /// The pull request the workspace's `github-pr` annotation links to.
    static func pullRequestLink(in workspace: WorkspaceState) -> WorkspacePullRequestLink? {
        WorkspacePullRequestLink(
            annotationURL: workspace.annotations[SidebarSubspacePresentation.annotationKeyPullRequest]?.url
        )
    }

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

}

/// Runs a click on a workspace's Merge button or its Close Without Merging
/// item: finds the pull request and the task's checkout, then hands them to
/// `WorkspaceMergeCoordinator`, which runs the pull request script.
@MainActor
struct WorkspaceMergeController {
    enum Problem: Equatable {
        /// No session or terminal in the workspace has a directory to find
        /// the task's checkout from.
        case noCheckoutPath
    }

    let store: AppStore
    let sessionRuntimeStore: SessionRuntimeStore
    var merge: @MainActor (
        _ workspaceID: UUID,
        _ pullRequest: WorkspacePullRequestLink,
        _ repoPath: String,
        _ thenCleanUp: Bool
    ) -> Void
    var closeWithoutMerging: @MainActor (
        _ workspaceID: UUID,
        _ pullRequest: WorkspacePullRequestLink,
        _ repoPath: String
    ) -> Void
    var presentProblem: @MainActor (_ problem: Problem, _ title: String, _ pullRequest: String) -> Void =
        WorkspaceMergeController.presentAlert
    /// Asks the user to confirm Close Without Merging.
    var confirmClose: @MainActor (_ pullRequest: WorkspacePullRequestLink) -> Bool =
        WorkspaceMergeController.confirmCloseAlert

    static func live(store: AppStore, sessionRuntimeStore: SessionRuntimeStore) -> Self {
        Self(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            merge: { workspaceID, pullRequest, repoPath, thenCleanUp in
                sessionRuntimeStore.workspaceMergeCoordinator?.merge(
                    workspaceID: workspaceID,
                    pullRequest: pullRequest,
                    repoPath: repoPath,
                    thenCleanUp: thenCleanUp
                )
            },
            closeWithoutMerging: { workspaceID, pullRequest, repoPath in
                sessionRuntimeStore.workspaceMergeCoordinator?.closeWithoutMerging(
                    workspaceID: workspaceID,
                    pullRequest: pullRequest,
                    repoPath: repoPath
                )
            }
        )
    }

    func requestMerge(workspaceID: UUID, mode: WorkspaceMergeMode) {
        guard let target = readyTarget(workspaceID: workspaceID, problemTitle: "Unable to Merge") else { return }
        merge(workspaceID, target.link, target.repoPath, mode == .mergeAndCleanUp)
    }

    /// Runs Close Without Merging after the user confirms it. It is offered
    /// only while the Merge button is ready, never through the shortcut.
    func requestClose(workspaceID: UUID) {
        guard let target = readyTarget(workspaceID: workspaceID, problemTitle: "Unable to Close"),
              confirmClose(target.link) else {
            return
        }
        closeWithoutMerging(workspaceID, target.link, target.repoPath)
    }

    /// The pull request and checkout of a workspace whose Merge button is
    /// ready, or `nil` after showing why there are none.
    private func readyTarget(
        workspaceID: UUID,
        problemTitle: String
    ) -> (pullRequest: String, link: WorkspacePullRequestLink, repoPath: String)? {
        guard let workspace = store.state.workspacesByID[workspaceID],
              case .ready(let pullRequest, _)? = WorkspaceMergePresentation.make(
                workspace: workspace,
                request: sessionRuntimeStore.workspaceMergeRequests[workspaceID]
              ),
              let link = WorkspaceMergePresentation.pullRequestLink(in: workspace) else {
            return nil
        }
        guard let repoPath = checkoutPath(in: workspace) else {
            presentProblem(.noCheckoutPath, problemTitle, pullRequest)
            return nil
        }
        return (pullRequest, link, repoPath)
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

    static func alertText(for problem: Problem, title: String, pullRequest: String) -> (title: String, message: String) {
        switch problem {
        case .noCheckoutPath:
            return (
                "\(title) \(pullRequest)",
                "Toastty could not find this workspace's checkout. Open a terminal in the worktree and try again."
            )
        }
    }

    private static func confirmCloseAlert(pullRequest: WorkspacePullRequestLink) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close \(pullRequest.displayName) Without Merging?"
        alert.informativeText = "Toastty closes \(pullRequest.url) on GitHub, closes this workspace and ends its "
            + "sessions, removes its worktree, and deletes the local branch. The branch stays on GitHub, "
            + "so you can reopen the pull request."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Pull Request")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func presentAlert(_ problem: Problem, title: String, pullRequest: String) {
        let text = alertText(for: problem, title: title, pullRequest: pullRequest)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
