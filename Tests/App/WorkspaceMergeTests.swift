import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// A task subspace with a pull request annotation, plus a merge controller
/// whose terminal and agent-launch effects are recorded instead of run.
@MainActor
private final class WorkspaceMergeFixture {
    let store: AppStore
    let sessionRuntimeStore = SessionRuntimeStore()
    let windowID: UUID
    let taskWorkspaceID: UUID
    let taskPanelID: UUID
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    var sentPrompts: [(prompt: String, panelID: UUID)] = []
    var launches: [(profileID: String, panelID: UUID, prompt: String)] = []
    var problems: [WorkspaceMergeController.Problem] = []
    var draftConfirmationCount = 0
    var confirmsSendOverPossibleDraft = true
    var launchError: Error?
    var profiles = [
        AgentProfile(id: "codex", displayName: "Codex", argv: ["codex"]),
        AgentProfile(id: "claude", displayName: "Claude Code", argv: ["claude"]),
    ]
    var promptState = TerminalPromptState.idleAtPrompt

    init(pullRequest: String? = "PR #59") throws {
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
        if let pullRequest {
            store.send(.setWorkspaceAnnotation(
                workspaceID: taskWorkspaceID,
                key: "github-pr",
                annotation: try #require(WorkspaceAnnotation.validated(
                    text: pullRequest,
                    url: "https://github.com/example/toastty/pull/59"
                ))
            ))
        }
    }

    var controller: WorkspaceMergeController {
        WorkspaceMergeController(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            agentProfiles: { [unowned self] in profiles },
            sendPrompt: { [unowned self] prompt, panelID in
                sentPrompts.append((prompt, panelID))
                return true
            },
            promptState: { [unowned self] _ in promptState },
            launchAgent: { [unowned self] profileID, workspaceID, panelID, prompt in
                launches.append((profileID, panelID, prompt))
                // The real launch prepares skills before the agent starts.
                await Task.yield()
                if let launchError {
                    throw launchError
                }
                let sessionID = "launched-\(launches.count)"
                // A just-launched agent has not reported a status yet.
                startAgent(sessionID: sessionID, agent: try #require(AgentKind(rawValue: profileID)), status: nil)
                return sessionID
            },
            confirmSendOverPossibleDraft: { [unowned self] _ in
                draftConfirmationCount += 1
                return confirmsSendOverPossibleDraft
            },
            presentProblem: { [unowned self] problem, _ in problems.append(problem) }
        )
    }

    var presentation: WorkspaceMergePresentation? {
        guard let workspace = store.state.workspacesByID[taskWorkspaceID] else { return nil }
        return WorkspaceMergePresentation.make(
            workspace: workspace,
            request: sessionRuntimeStore.workspaceMergeRequests[taskWorkspaceID]
        )
    }

    /// Starts an agent session in the task workspace. It reports idle, as an
    /// agent waiting at its input does, unless `status` is `nil`.
    func startAgent(
        sessionID: String = "task-agent",
        agent: AgentKind = .claude,
        status: SessionStatusKind? = .idle
    ) {
        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: agent,
            panelID: taskPanelID,
            windowID: windowID,
            workspaceID: taskWorkspaceID,
            cwd: nil,
            repoRoot: nil,
            at: start
        )
        if let status {
            report(status, sessionID: sessionID, at: 0)
        }
    }

    func report(_ kind: SessionStatusKind, sessionID: String = "task-agent", at offset: TimeInterval) {
        sessionRuntimeStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: kind, summary: "\(kind)", detail: nil),
            at: start.addingTimeInterval(offset)
        )
    }
}

@MainActor
struct WorkspaceMergeTests {
    @Test
    func mergeSendsThePromptToTheAgentAtRestAndFollowsItToDone() throws {
        let fixture = try WorkspaceMergeFixture()
        fixture.startAgent()
        fixture.report(.working, at: 1)
        fixture.report(.ready, at: 2)
        #expect(fixture.presentation == .ready(pullRequest: "PR #59"))
        #expect(fixture.presentation?.title == "Merge PR #59")

        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)

        #expect(fixture.sentPrompts.count == 1)
        #expect(fixture.sentPrompts.first?.panelID == fixture.taskPanelID)
        let prompt = try #require(fixture.sentPrompts.first?.prompt)
        #expect(prompt.contains("PR #59"))
        #expect(prompt.contains("worktree-done"))
        #expect(prompt.contains("workspace.set-done"))
        #expect(prompt.contains("\n") == false)
        #expect(fixture.presentation?.title == "Merging PR #59…")

        // A second click while the agent has the request does nothing.
        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)
        #expect(fixture.sentPrompts.count == 1)

        // The agent picks the prompt up, pauses on an approval, then marks
        // the workspace done in the middle of its turn.
        fixture.report(.working, at: 3)
        fixture.report(.needsApproval, at: 4)
        #expect(fixture.presentation?.title == "Merging PR #59…")
        fixture.store.send(.setWorkspaceDone(workspaceID: fixture.taskWorkspaceID, doneAt: fixture.start))

        #expect(fixture.presentation?.title == "Done · PR #59")
        #expect(fixture.sessionRuntimeStore.workspaceMergeRequests.isEmpty)
        fixture.report(.ready, at: 5)
        #expect(fixture.presentation?.title == "Done · PR #59")
        #expect(fixture.problems.isEmpty)
        #expect(fixture.draftConfirmationCount == 0)
    }

    @Test
    func mergeOffersTheButtonAgainWhenTheTurnEndsWithoutTheDoneMark() throws {
        let fixture = try WorkspaceMergeFixture()
        fixture.startAgent()
        fixture.report(.idle, at: 1)

        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)
        // Reading the panel collapses an unread ready status to idle; a
        // status change at rest is not the merge turn ending.
        fixture.report(.idle, at: 2)
        #expect(fixture.presentation?.title == "Merging PR #59…")

        // The agent stops to ask about a prerequisite instead of merging.
        fixture.report(.working, at: 3)
        fixture.report(.ready, at: 4)

        #expect(fixture.presentation == .ready(pullRequest: "PR #59"))
    }

    @Test
    func mergeOffersTheButtonAgainWhenTheAgentExits() throws {
        let fixture = try WorkspaceMergeFixture()
        fixture.startAgent()
        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)
        #expect(fixture.presentation?.title == "Merging PR #59…")

        fixture.sessionRuntimeStore.stopSession(sessionID: "task-agent", at: fixture.start.addingTimeInterval(5))

        #expect(fixture.presentation == .ready(pullRequest: "PR #59"))
    }

    @Test
    func mergeAsksTheUserToWaitWhileTheAgentIsMidTurn() throws {
        let fixture = try WorkspaceMergeFixture()
        fixture.startAgent()
        fixture.report(.working, at: 1)

        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)

        #expect(fixture.problems == [.agentBusy])
        #expect(fixture.sentPrompts.isEmpty)
        #expect(fixture.launches.isEmpty)
        #expect(fixture.presentation == .ready(pullRequest: "PR #59"))
    }

    @Test
    func mergeStartsTheWorkspacesLastAgentWhenNoneIsRunning() async throws {
        let fixture = try WorkspaceMergeFixture()
        fixture.startAgent(sessionID: "earlier", agent: .claude)
        fixture.sessionRuntimeStore.stopSession(sessionID: "earlier", at: fixture.start.addingTimeInterval(1))

        let launch = try #require(fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID))
        // The button shows progress while the agent launches, and a second
        // click does not start a second agent.
        #expect(fixture.presentation?.title == "Merging PR #59…")
        #expect(fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID) == nil)
        await launch.value

        // Claude ran here last, so it wins over the first configured profile.
        #expect(fixture.launches.map(\.profileID) == ["claude"])
        #expect(fixture.launches.first?.panelID == fixture.taskPanelID)
        #expect(fixture.launches.first?.prompt.contains("PR #59") == true)
        #expect(fixture.sentPrompts.isEmpty)
        #expect(fixture.presentation?.title == "Merging PR #59…")

        fixture.report(.working, sessionID: "launched-1", at: 2)
        fixture.store.send(.setWorkspaceDone(workspaceID: fixture.taskWorkspaceID, doneAt: fixture.start))
        #expect(fixture.presentation?.title == "Done · PR #59")
    }

    @Test
    func mergeOffersTheButtonAgainWhenTheAgentCannotLaunch() async throws {
        let fixture = try WorkspaceMergeFixture()

        // A profile with extra arguments cannot take a first message unless
        // it declares where the prompt goes.
        fixture.launchError = AgentLaunchError.initialPromptUnsupported(profileID: "codex")
        await fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)?.value
        #expect(fixture.problems == [.profileCannotTakePrompt(profileID: "codex")])
        #expect(fixture.presentation == .ready(pullRequest: "PR #59"))

        fixture.launchError = AgentLaunchError.panelBusy(runningCommand: "make")
        await fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)?.value
        #expect(fixture.problems.last == .launchFailed("The target terminal is still busy: make"))
        #expect(fixture.presentation == .ready(pullRequest: "PR #59"))
    }

    @Test
    func mergeWaitsWhileTheAgentsSubAgentsStillRun() throws {
        let fixture = try WorkspaceMergeFixture()
        fixture.startAgent()
        fixture.report(.working, at: 1)
        // The agent's own turn ended, but its row still shows working.
        _ = fixture.sessionRuntimeStore.updateBackgroundActivity(
            sessionID: "task-agent",
            activity: SessionBackgroundActivity(
                id: "review",
                kind: .subagent,
                displayName: "Review",
                startedAt: fixture.start,
                lastUpdatedAt: fixture.start
            ),
            at: fixture.start.addingTimeInterval(2)
        )
        fixture.report(.ready, at: 3)

        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)

        #expect(fixture.problems == [.agentBusy])
        #expect(fixture.sentPrompts.isEmpty)
    }

    @Test
    func mergeAsksBeforeSendingOverInputTheUserMayNotHaveSent() throws {
        let fixture = try WorkspaceMergeFixture()
        fixture.startAgent()
        fixture.report(.working, at: 1)
        fixture.report(.ready, at: 2)
        // The user typed in the agent's terminal after its turn ended.
        fixture.sessionRuntimeStore.noteLocalInputForActiveSession(panelID: fixture.taskPanelID)

        fixture.confirmsSendOverPossibleDraft = false
        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)
        #expect(fixture.draftConfirmationCount == 1)
        #expect(fixture.sentPrompts.isEmpty)
        #expect(fixture.presentation == .ready(pullRequest: "PR #59"))

        fixture.confirmsSendOverPossibleDraft = true
        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)
        #expect(fixture.draftConfirmationCount == 2)
        #expect(fixture.sentPrompts.count == 1)

        // Input sent as a turn is no longer a draft: once the next turn has
        // started and ended, merging needs no confirmation.
        fixture.report(.working, at: 3)
        fixture.report(.ready, at: 4)
        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)
        #expect(fixture.draftConfirmationCount == 2)
        #expect(fixture.sentPrompts.count == 2)
    }

    @Test
    func mergeExplainsWhenNoAgentCanStart() throws {
        let fixture = try WorkspaceMergeFixture()

        // The only terminal is running something, so an agent cannot start.
        fixture.promptState = .busy
        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)
        #expect(fixture.problems == [.noIdleTerminal])

        fixture.promptState = .idleAtPrompt
        fixture.profiles = []
        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)
        #expect(fixture.problems == [.noIdleTerminal, .noAgentProfile])

        #expect(fixture.launches.isEmpty)
        #expect(fixture.presentation == .ready(pullRequest: "PR #59"))
    }

    @Test
    func configuredPromptReplacesTheBuiltInPrompt() throws {
        let fixture = try WorkspaceMergeFixture()
        fixture.startAgent()
        fixture.store.setPullRequestMergePrompt("/ship-it")

        fixture.controller.requestMerge(workspaceID: fixture.taskWorkspaceID)

        #expect(fixture.sentPrompts.map(\.prompt) == ["/ship-it"])
    }

    @Test
    func onlyASubspaceWithAPullRequestGetsTheMergeControl() throws {
        let withoutPullRequest = try WorkspaceMergeFixture(pullRequest: nil)
        #expect(withoutPullRequest.presentation == nil)
        withoutPullRequest.startAgent()
        withoutPullRequest.controller.requestMerge(workspaceID: withoutPullRequest.taskWorkspaceID)
        #expect(withoutPullRequest.sentPrompts.isEmpty)

        // A top-level workspace cannot hold the done mark that ends a merge.
        let fixture = try WorkspaceMergeFixture()
        fixture.store.send(.setWorkspaceParent(
            workspaceID: fixture.taskWorkspaceID,
            parentWorkspaceID: nil,
            spawningSessionID: nil
        ))
        #expect(fixture.presentation == nil)
    }
}
