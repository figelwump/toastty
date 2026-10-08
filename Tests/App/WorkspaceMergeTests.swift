import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// A task subspace with a pull request annotation, plus a merge controller
/// whose coordinator calls and alerts are recorded instead of run.
@MainActor
private final class WorkspaceMergeFixture {
    let store: AppStore
    let sessionRuntimeStore = SessionRuntimeStore()
    let windowID: UUID
    let taskWorkspaceID: UUID
    let taskPanelID: UUID
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    var merges: [(workspaceID: UUID, pullRequest: WorkspacePullRequestLink, repoPath: String, thenCleanUp: Bool)] = []
    var closes: [(workspaceID: UUID, pullRequest: WorkspacePullRequestLink, repoPath: String)] = []
    var problems: [WorkspaceMergeController.Problem] = []
    var closeConfirmations: [String] = []
    var confirmsClose = true

    init(
        pullRequestText: String = "PR #59",
        pullRequestURL: String? = "https://github.com/example/toastty/pull/59"
    ) throws {
        store = AppStore(persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        windowID = selection.windowID
        sessionRuntimeStore.bind(store: store)

        let existingWorkspaceIDs = Set(store.state.workspacesByID.keys)
        store.send(.createWorkspace(windowID: windowID, title: "fix-question-lifetime", activate: false))
        taskWorkspaceID = try #require(
            Set(store.state.workspacesByID.keys).subtracting(existingWorkspaceIDs).first
        )
        taskPanelID = try #require(store.state.workspacesByID[taskWorkspaceID]?.focusedPanelID)
        store.send(.setWorkspaceParent(
            workspaceID: taskWorkspaceID,
            parentWorkspaceID: selection.workspaceID,
            spawningSessionID: nil
        ))
        store.send(.setWorkspaceAnnotation(
            workspaceID: taskWorkspaceID,
            key: "github-pr",
            annotation: try #require(WorkspaceAnnotation.validated(text: pullRequestText, url: pullRequestURL))
        ))
        store.send(.updateTerminalPanelMetadata(panelID: taskPanelID, title: nil, cwd: "/work/toastty-fix-question"))
    }

    var controller: WorkspaceMergeController {
        WorkspaceMergeController(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            merge: { [unowned self] workspaceID, pullRequest, repoPath, thenCleanUp in
                merges.append((workspaceID, pullRequest, repoPath, thenCleanUp))
            },
            closeWithoutMerging: { [unowned self] workspaceID, pullRequest, repoPath in
                closes.append((workspaceID, pullRequest, repoPath))
            },
            presentProblem: { [unowned self] problem, _, _ in problems.append(problem) },
            confirmClose: { [unowned self] pullRequest in
                closeConfirmations.append(pullRequest.displayName)
                return confirmsClose
            }
        )
    }

    /// Clicks the Merge button in the mode the store holds, or in `mode`.
    func merge(_ mode: WorkspaceMergeMode? = nil) {
        controller.requestMerge(workspaceID: taskWorkspaceID, mode: mode ?? store.workspaceMergeMode)
    }

    var presentation: WorkspaceMergePresentation? {
        guard let workspace = store.state.workspacesByID[taskWorkspaceID] else { return nil }
        return WorkspaceMergePresentation.make(
            workspace: workspace,
            request: sessionRuntimeStore.workspaceMergeRequests[taskWorkspaceID],
            mode: store.workspaceMergeMode
        )
    }

    func setRequest(_ phase: WorkspaceMergeRequest.Phase) throws {
        let link = try #require(WorkspacePullRequestLink(annotationURL: "https://github.com/example/toastty/pull/59"))
        sessionRuntimeStore.setWorkspaceMergeRequests([
            taskWorkspaceID: WorkspaceMergeRequest(pullRequest: link, repoPath: "/work/task", phase: phase),
        ])
    }
}

@MainActor
struct WorkspaceMergeTests {
    @Test
    func mergeHandsThePullRequestAndCheckoutToTheCoordinatorInTheChosenMode() throws {
        let fixture = try WorkspaceMergeFixture()
        #expect(fixture.presentation == .ready(pullRequest: "PR #59", mode: .mergeAndCleanUp))
        #expect(fixture.presentation?.title == "Merge & Clean PR #59")
        // An agent's repository root wins over a terminal's directory.
        fixture.sessionRuntimeStore.startSession(
            sessionID: "task-agent",
            agent: .claude,
            panelID: fixture.taskPanelID,
            windowID: fixture.windowID,
            workspaceID: fixture.taskWorkspaceID,
            cwd: "/work/toastty-fix-question/Sources",
            repoRoot: "/work/toastty-fix-question-root",
            at: fixture.start
        )

        fixture.merge()
        fixture.store.setWorkspaceMergeMode(.mergeOnly)
        #expect(fixture.presentation?.title == "Merge PR #59")
        fixture.merge()

        #expect(fixture.merges.map(\.thenCleanUp) == [true, false])
        let merge = try #require(fixture.merges.first)
        #expect(merge.workspaceID == fixture.taskWorkspaceID)
        #expect(merge.pullRequest.number == 59)
        #expect(merge.pullRequest.url == "https://github.com/example/toastty/pull/59")
        #expect(merge.repoPath == "/work/toastty-fix-question-root")
        #expect(fixture.problems.isEmpty)
    }

    @Test
    func onlyASubspaceWithAPullRequestGetsTheMergeControl() throws {
        // A top-level workspace cannot hold the done mark that records a merge.
        let fixture = try WorkspaceMergeFixture()
        fixture.store.send(.setWorkspaceParent(
            workspaceID: fixture.taskWorkspaceID,
            parentWorkspaceID: nil,
            spawningSessionID: nil
        ))
        #expect(fixture.presentation == nil)
        fixture.merge()
        #expect(fixture.merges.isEmpty)
        #expect(fixture.problems.isEmpty)
    }

    @Test
    func theButtonNamesThePullRequestItsURLLinksTo() throws {
        // The annotation's text is free-form and set separately from its URL,
        // so it never labels the button.
        let mislabeled = try WorkspaceMergeFixture(
            pullRequestText: "PR #65",
            pullRequestURL: "https://github.com/other/repo/pull/7/files"
        )
        #expect(mislabeled.presentation?.title == "Merge & Clean PR #7")
        mislabeled.controller.requestClose(workspaceID: mislabeled.taskWorkspaceID)
        #expect(mislabeled.closeConfirmations == ["other/repo#7"])

        // Without a GitHub pull request URL there is nothing to act on.
        let withoutURL = try WorkspaceMergeFixture(pullRequestURL: nil)
        #expect(withoutURL.presentation == nil)
        withoutURL.merge()
        withoutURL.controller.requestClose(workspaceID: withoutURL.taskWorkspaceID)
        #expect(withoutURL.merges.isEmpty)
        #expect(withoutURL.closeConfirmations.isEmpty)
        #expect(withoutURL.problems.isEmpty)
    }

    @Test
    func requestPhasesReplaceTheButton() throws {
        let fixture = try WorkspaceMergeFixture()
        try fixture.setRequest(.merging(thenCleanUp: true))
        #expect(fixture.presentation?.title == "Merging PR #59…")
        // A second click while the merge runs does nothing.
        fixture.merge()
        #expect(fixture.merges.isEmpty)

        fixture.store.send(.setWorkspaceDone(workspaceID: fixture.taskWorkspaceID, doneAt: fixture.start))
        try fixture.setRequest(.awaitingMerge)
        #expect(fixture.presentation?.title == "Cleans Up When PR #59 Merges")
        // Waiting for checks shows as the merge the user accepted.
        try fixture.setRequest(.awaitingChecks(acceptedHead: "a1b2c3d4", thenCleanUp: true))
        #expect(fixture.presentation?.title == "Cleans Up When PR #59 Merges")
        try fixture.setRequest(.awaitingChecks(acceptedHead: "a1b2c3d4", thenCleanUp: false))
        #expect(fixture.presentation?.title == "Done · PR #59")
        try fixture.setRequest(.cleaningUp)
        #expect(fixture.presentation?.title == "Cleaning Up PR #59…")
        try fixture.setRequest(.failed(reason: "the worktree has uncommitted changes"))
        #expect(fixture.presentation == .cleanupFailed(
            pullRequest: "PR #59",
            reason: "the worktree has uncommitted changes"
        ))
        fixture.sessionRuntimeStore.setWorkspaceMergeRequests([:])
        #expect(fixture.presentation?.title == "Done · PR #59")

        fixture.store.send(.setWorkspaceDone(workspaceID: fixture.taskWorkspaceID, doneAt: nil))
        try fixture.setRequest(.closing)
        #expect(fixture.presentation?.title == "Closing PR #59…")
    }

    @Test
    func closeWithoutMergingRunsOnlyAfterTheUserConfirms() throws {
        let fixture = try WorkspaceMergeFixture()
        fixture.confirmsClose = false

        fixture.controller.requestClose(workspaceID: fixture.taskWorkspaceID)
        #expect(fixture.closeConfirmations == ["example/toastty#59"])
        #expect(fixture.closes.isEmpty)

        fixture.confirmsClose = true
        fixture.controller.requestClose(workspaceID: fixture.taskWorkspaceID)
        #expect(fixture.closes.count == 1)
        #expect(fixture.closes.first?.workspaceID == fixture.taskWorkspaceID)
        #expect(fixture.closes.first?.pullRequest.url == "https://github.com/example/toastty/pull/59")
        #expect(fixture.closes.first?.repoPath == "/work/toastty-fix-question")
        #expect(fixture.merges.isEmpty)
    }

    @Test
    func closeWithoutMergingIsOfferedOnlyWhileTheButtonIsReady() throws {
        let fixture = try WorkspaceMergeFixture()
        try fixture.setRequest(.merging(thenCleanUp: false))

        fixture.controller.requestClose(workspaceID: fixture.taskWorkspaceID)

        #expect(fixture.closeConfirmations.isEmpty)
        #expect(fixture.closes.isEmpty)
    }
}
