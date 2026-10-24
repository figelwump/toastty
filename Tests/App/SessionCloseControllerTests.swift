@testable import ToasttyApp
import CoreState
import Foundation
import RemoteProtocol
import XCTest

@MainActor
final class SessionCloseControllerTests: XCTestCase {
    // Failure modes: a busy or just-launched agent closed silently, a finished
    // agent still asking, a background close switching the visible tab or
    // workspace, a workspace's only tab closed without asking (which removes
    // the workspace), and a missing terminal assessment treated as idle.

    func testFinishedAgentClosesWithoutAskingAndKeepsTheSelectedTab() throws {
        let fixture = try makeFixture()
        fixture.startAgent()
        fixture.setStatus(.working)
        fixture.setStatus(.ready)
        let selectedTabBefore = fixture.selectedTabID

        let result = fixture.controller.closeSession(
            panelID: fixture.agentPanelID, stopIfBusy: false, source: .command("test")
        )

        XCTAssertEqual(result, .closed)
        XCTAssertNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.agentPanelID))
        XCTAssertNil(fixture.workspace.tab(id: fixture.agentTabID), "The agent's only pane takes its tab with it")
        XCTAssertEqual(fixture.selectedTabID, selectedTabBefore)
    }

    func testIdleAfterAFinishedTurnClosesWithoutAsking() throws {
        let fixture = try makeFixture()
        fixture.startAgent()
        fixture.setStatus(.working)
        fixture.setStatus(.idle)

        XCTAssertEqual(
            fixture.controller.closeSession(panelID: fixture.agentPanelID, stopIfBusy: false, source: .command("test")),
            .closed
        )
    }

    func testFreshLaunchAsksBecauseIdleBeforeTheFirstTurnIsNotEvidence() throws {
        let fixture = try makeFixture()
        fixture.startAgent()
        fixture.setStatus(.idle)

        XCTAssertEqual(
            fixture.controller.closeSession(panelID: fixture.agentPanelID, stopIfBusy: false, source: .command("test")),
            .confirmationRequired(detail: "Claude Code")
        )
        XCTAssertNotNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.agentPanelID))
    }

    func testWorkingAgentAsksThenStopsWhenTheUserAgrees() throws {
        let fixture = try makeFixture()
        fixture.startAgent()
        fixture.setStatus(.working)

        XCTAssertEqual(
            fixture.controller.closeSession(panelID: fixture.agentPanelID, stopIfBusy: false, source: .command("test")),
            .confirmationRequired(detail: "Claude Code")
        )
        XCTAssertNotNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.agentPanelID))

        XCTAssertEqual(
            fixture.controller.closeSession(panelID: fixture.agentPanelID, stopIfBusy: true, source: .command("test")),
            .closed
        )
        XCTAssertNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.agentPanelID))
    }

    func testWithoutAnAgentTheTerminalProcessCheckDecides() throws {
        let running = try makeFixture(
            terminalAssessment: TerminalCloseConfirmationAssessment(requiresConfirmation: true, runningCommand: "sleep 30")
        )
        XCTAssertEqual(
            running.controller.closeSession(panelID: running.agentPanelID, stopIfBusy: false, source: .command("test")),
            .confirmationRequired(detail: "sleep 30")
        )

        let unknown = try makeFixture(terminalAssessment: nil)
        XCTAssertEqual(
            unknown.controller.closeSession(panelID: unknown.agentPanelID, stopIfBusy: false, source: .command("test")),
            .confirmationRequired(detail: nil)
        )

        let idleShell = try makeFixture(
            terminalAssessment: TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        )
        XCTAssertEqual(
            idleShell.controller.closeSession(panelID: idleShell.agentPanelID, stopIfBusy: false, source: .command("test")),
            .closed
        )
    }

    func testClosingAWorkspacesOnlyTabAsksFirstEvenWhenStopping() throws {
        let fixture = try makeFixture(addsSecondTab: false)
        fixture.startAgent()
        fixture.setStatus(.working)
        fixture.setStatus(.ready)
        let id = fixture.workspaceID
        let title = fixture.workspace.title

        XCTAssertEqual(
            fixture.controller.closeSession(panelID: fixture.agentPanelID, stopIfBusy: true, source: .command("test")),
            .workspaceCloseConfirmationRequired(.init(workspaceID: id, workspaceTitle: title, isRunning: false, runningDetail: nil))
        )
        fixture.setStatus(.working)
        XCTAssertEqual(
            fixture.controller.closeSession(panelID: fixture.agentPanelID, stopIfBusy: false, source: .command("test")),
            .workspaceCloseConfirmationRequired(
                .init(workspaceID: id, workspaceTitle: title, isRunning: true, runningDetail: "Claude Code")
            )
        )
        // Consent to close another workspace does not cover this one.
        XCTAssertEqual(
            fixture.controller.closeSession(
                panelID: fixture.agentPanelID, stopIfBusy: true, confirmedWorkspaceCloseID: UUID(), source: .command("test")
            ),
            .workspaceCloseConfirmationRequired(
                .init(workspaceID: id, workspaceTitle: title, isRunning: true, runningDetail: "Claude Code")
            )
        )
        XCTAssertNotNil(fixture.store.state.workspacesByID[fixture.workspaceID])
    }

    func testWorkspacePermissionClosesTheWorkspaceAndKeepsTheSelectedWorkspace() throws {
        let fixture = try makeFixture(addsSecondTab: false, addsSecondWorkspace: true)
        fixture.startAgent()
        fixture.setStatus(.working)
        fixture.setStatus(.ready)
        let selectedWorkspaceBefore = fixture.store.state.windows[0].selectedWorkspaceID
        XCTAssertNotEqual(selectedWorkspaceBefore, fixture.workspaceID)

        XCTAssertEqual(
            fixture.controller.closeSession(
                panelID: fixture.agentPanelID, stopIfBusy: false, confirmedWorkspaceCloseID: fixture.workspaceID,
                source: .command("test")
            ),
            .closed
        )
        XCTAssertNil(fixture.store.state.workspacesByID[fixture.workspaceID])
        XCTAssertEqual(fixture.store.state.windows[0].selectedWorkspaceID, selectedWorkspaceBefore)
    }

    func testInteractiveCloseAsksAndHonorsCancel() throws {
        var confirmations: [String?] = []
        var answer = false
        let fixture = try makeFixture(confirmStopAndClose: { _, detail in
            confirmations.append(detail)
            return answer
        })
        fixture.startAgent()
        fixture.setStatus(.working)

        fixture.controller.closeSessionInteractively(panelID: fixture.agentPanelID, sessionTitle: "Fix login")
        XCTAssertEqual(confirmations, ["Claude Code"])
        XCTAssertNotNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.agentPanelID))

        answer = true
        fixture.controller.closeSessionInteractively(panelID: fixture.agentPanelID, sessionTitle: "Fix login")
        XCTAssertEqual(confirmations.count, 2)
        XCTAssertNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.agentPanelID))
    }

    func testInteractiveWorkspaceCloseAsksOnceForAWorkingAgentAndHonorsCancel() throws {
        var prompts: [SessionCloseController.WorkspaceClose] = []
        var answer = false
        let fixture = try makeFixture(addsSecondTab: false, confirmWorkspaceClose: { _, close in
            prompts.append(close)
            return answer
        })
        fixture.startAgent()
        fixture.setStatus(.working)

        fixture.controller.closeSessionInteractively(panelID: fixture.agentPanelID, sessionTitle: "Fix login")
        XCTAssertEqual(prompts.map(\.isRunning), [true])
        XCTAssertNotNil(fixture.store.state.workspacesByID[fixture.workspaceID])

        // The fixture fails on a separate stop confirmation, so one prompt
        // covers stopping the agent too.
        answer = true
        fixture.controller.closeSessionInteractively(panelID: fixture.agentPanelID, sessionTitle: "Fix login")
        XCTAssertEqual(prompts.count, 2)
        XCTAssertNil(fixture.store.state.workspacesByID[fixture.workspaceID])
    }

    func testClosingATaskSpaceAsksTheTaskQuestionInPlaceOfTheWorkspaceConfirmation() throws {
        var questions: [TaskSpaceCloseQuestion] = []
        var applied: [TaskSpaceCloseChoice] = []
        var answer: TaskSpaceCloseChoice?
        var workspaceID: UUID?
        // The fixture fails on the workspace confirmation, so the question
        // is the only dialog.
        let fixture = try makeFixture(addsSecondTab: false, taskSpaceCloseAsker: TaskSpaceCloseAsker(
            question: { id in
                id == workspaceID ? TaskSpaceCloseQuestion(taskID: UUID(), taskTitle: "Fix login", taskSpaceWorkspaceID: id) : nil
            },
            present: { question in
                questions.append(question)
                return answer
            },
            apply: { choice, _ in applied.append(choice) }
        ))
        workspaceID = fixture.workspaceID
        fixture.startAgent()
        fixture.setStatus(.working)

        fixture.controller.closeSessionInteractively(panelID: fixture.agentPanelID, sessionTitle: "Fix login")
        XCTAssertEqual(questions.count, 1)
        XCTAssertTrue(questions[0].warning?.contains("Claude Code is still running") == true)
        XCTAssertNotNil(fixture.store.state.workspacesByID[fixture.workspaceID], "Cancel closes nothing")
        XCTAssertEqual(applied, [])

        answer = .archive
        fixture.controller.closeSessionInteractively(panelID: fixture.agentPanelID, sessionTitle: "Fix login")
        XCTAssertEqual(questions.count, 2)
        XCTAssertNil(fixture.store.state.workspacesByID[fixture.workspaceID])
        XCTAssertEqual(applied, [.archive])
    }

    func testAnAgentExitThatClosesATaskSpacePaneDoesNotAsk() throws {
        let fixture = try makeFixture(taskSpaceCloseAsker: TaskSpaceCloseAsker(
            question: { TaskSpaceCloseQuestion(taskID: UUID(), taskTitle: "Fix login", taskSpaceWorkspaceID: $0) },
            present: { _ in
                XCTFail("Unexpected task question")
                return nil
            },
            apply: { _, _ in XCTFail("Unexpected task choice") }
        ))
        fixture.startAgent()
        fixture.setStatus(.working)
        fixture.setStatus(.ready)

        XCTAssertEqual(fixture.controller.closeExitedSessionPane(panelID: fixture.agentPanelID), .closed)
    }

    func testWorkspaceCloseMessageWarnsAboutTheWorktree() {
        let message = SessionCloseController.workspaceCloseMessage(
            .init(workspaceID: UUID(), workspaceTitle: "fix-login", isRunning: true, runningDetail: "Codex")
        )
        XCTAssertTrue(message.contains("\u{201C}fix-login\u{201D}"))
        XCTAssertTrue(message.contains("Codex is still running"))
        XCTAssertTrue(message.contains("git worktree is not cleaned up automatically"))
        XCTAssertFalse(
            SessionCloseController.workspaceCloseMessage(
                .init(workspaceID: UUID(), workspaceTitle: "w", isRunning: false, runningDetail: nil)
            )
                .contains("still running")
        )
    }

    func testAnUnsavedRightPanelDocumentInTheClosingTabIsRefusedEvenWhenStopping() throws {
        let fixture = try makeFixture(
            rightPanelDocumentState: LocalDocumentCloseConfirmationState(kind: .dirtyDraft, displayName: "plan.md")
        )
        fixture.startAgent()
        fixture.setStatus(.working)
        fixture.setStatus(.ready)

        XCTAssertEqual(
            fixture.controller.closeSession(panelID: fixture.agentPanelID, stopIfBusy: true, source: .command("test")),
            .unsavedDocument(displayName: "plan.md")
        )
        XCTAssertNotNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.agentPanelID))
    }

    func testBypassedPromptsStillRefuseToDiscardADocumentDraft() throws {
        let fixture = try makeFixture(
            addsSecondTab: false,
            bypassesConfirmation: true,
            rightPanelDocumentState: LocalDocumentCloseConfirmationState(kind: .dirtyDraft, displayName: "plan.md")
        )
        fixture.startAgent()
        fixture.setStatus(.working)

        XCTAssertEqual(
            fixture.controller.closeSession(panelID: fixture.agentPanelID, stopIfBusy: false, source: .command("test")),
            .unsavedDocument(displayName: "plan.md")
        )
        XCTAssertNotNil(fixture.store.state.workspacesByID[fixture.workspaceID])
    }

    func testAResumingParentStillCountsAsBusy() throws {
        let fixture = try makeFixture()
        fixture.startAgent()
        fixture.setStatus(.working)
        fixture.setStatus(.ready)
        let record = try XCTUnwrap(fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: fixture.agentPanelID))

        XCTAssertEqual(AgentCloseReadiness.evaluate(record: record, projection: .none), .finished)
        XCTAssertEqual(AgentCloseReadiness.evaluate(record: record, projection: .resuming), .busy(agentName: "Claude Code"))
    }

    func testReadinessCountsWaitingOnChildrenAndProcessWatch() {
        let panelID = UUID()
        func record(agent: AgentKind = .claude, kind: SessionStatusKind?, lastTurn: TimeInterval? = 4) -> SessionRecord {
            SessionRecord(
                sessionID: "s", agent: agent, panelID: panelID, windowID: UUID(), workspaceID: UUID(),
                status: kind.map { SessionStatus(kind: $0, summary: "") }, lastTurnDuration: lastTurn,
                startedAt: Date(), updatedAt: Date()
            )
        }

        XCTAssertEqual(
            AgentCloseReadiness.evaluate(
                record: record(kind: .ready),
                projection: .waitingOnChildren(childCount: 1, pendingBackgroundTaskCount: 0)
            ),
            .busy(agentName: "Claude Code")
        )
        XCTAssertEqual(AgentCloseReadiness.evaluate(record: record(kind: .needsApproval), projection: .none), .busy(agentName: "Claude Code"))
        XCTAssertEqual(AgentCloseReadiness.evaluate(record: record(kind: .error), projection: .none), .finished)
        XCTAssertEqual(AgentCloseReadiness.evaluate(record: record(kind: nil), projection: .none), .busy(agentName: "Claude Code"))
        XCTAssertEqual(AgentCloseReadiness.evaluate(record: record(agent: .processWatch, kind: .working), projection: .none), .noAgent)
        XCTAssertEqual(AgentCloseReadiness.evaluate(record: nil, projection: .none), .noAgent)

        // A finished agent overrides the terminal's running-process answer,
        // and no agent defers to it.
        let running = TerminalCloseConfirmationAssessment(requiresConfirmation: true, runningCommand: "claude")
        XCTAssertEqual(AgentCloseReadiness.finished.terminalCloseAssessment { running }?.requiresConfirmation, false)
        XCTAssertEqual(AgentCloseReadiness.noAgent.terminalCloseAssessment { running }, running)
        XCTAssertNil(AgentCloseReadiness.noAgent.terminalCloseAssessment { nil })
        XCTAssertEqual(
            AgentCloseReadiness.busy(agentName: "Codex").terminalCloseAssessment { nil },
            TerminalCloseConfirmationAssessment(requiresConfirmation: true, runningCommand: "Codex")
        )
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let store: AppStore
        let sessionRuntimeStore: SessionRuntimeStore
        let controller: SessionCloseController
        let workspaceID: UUID
        let agentTabID: UUID
        let agentPanelID: UUID
        let sessionID = "close-test-session"

        var workspace: WorkspaceState { store.state.workspacesByID[workspaceID]! }
        var selectedTabID: UUID? { workspace.resolvedSelectedTabID }

        func startAgent() {
            sessionRuntimeStore.startSession(
                sessionID: sessionID, agent: .claude, panelID: agentPanelID,
                windowID: store.state.windows[0].id, workspaceID: workspaceID,
                codexStatusTrackingSource: .externallyReported, cwd: "/repo", repoRoot: "/repo", at: Date()
            )
        }

        func setStatus(_ kind: SessionStatusKind) {
            sessionRuntimeStore.updateStatus(
                sessionID: sessionID, status: SessionStatus(kind: kind, summary: "status"), at: Date()
            )
        }
    }

    /// The agent runs in the workspace's first tab. With `addsSecondTab`, a
    /// second tab is created and selected, so the agent's tab is in the
    /// background as when a session started from iOS.
    private func makeFixture(
        addsSecondTab: Bool = true,
        addsSecondWorkspace: Bool = false,
        bypassesConfirmation: Bool = false,
        terminalAssessment: TerminalCloseConfirmationAssessment? = TerminalCloseConfirmationAssessment(
            requiresConfirmation: true, runningCommand: "claude"
        ),
        rightPanelDocumentState: LocalDocumentCloseConfirmationState? = nil,
        confirmStopAndClose: (@MainActor (String, String?) -> Bool)? = nil,
        confirmWorkspaceClose: (@MainActor (String, SessionCloseController.WorkspaceClose) -> Bool)? = nil,
        presentRefusal: (@MainActor (String, String) -> Void)? = nil,
        taskSpaceCloseAsker: TaskSpaceCloseAsker = .never
    ) throws -> Fixture {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        let agentTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let agentPanelID = try XCTUnwrap(workspace.focusedPanelID)
        if let rightPanelDocumentState {
            XCTAssertTrue(store.send(.createWebPanel(
                workspaceID: workspace.id,
                panel: WebPanelState(
                    definition: .localDocument,
                    title: rightPanelDocumentState.displayName,
                    localDocument: LocalDocumentState(filePath: "/tmp/\(rightPanelDocumentState.displayName)")
                ),
                placement: .rightPanel
            )))
            XCTAssertEqual(store.state.workspacesByID[workspace.id]?.tab(id: agentTabID)?.rightAuxPanel.tabIDs.count, 1)
        }
        if addsSecondTab {
            XCTAssertTrue(store.send(.createWorkspaceTab(workspaceID: workspace.id, seed: nil)))
            XCTAssertNotEqual(store.state.workspacesByID[workspace.id]?.resolvedSelectedTabID, agentTabID)
        }
        if addsSecondWorkspace {
            XCTAssertTrue(store.send(.createWorkspace(windowID: store.state.windows[0].id, title: "Other", activate: true)))
        }
        let sessionRuntimeStore = SessionRuntimeStore()
        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: TerminalRuntimeRegistry(),
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
            shouldConfirmClose: true,
            terminalCloseAssessmentProvider: { _ in terminalAssessment }
        )
        let controller = SessionCloseController(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            terminalCloseAssessment: { _ in terminalAssessment },
            localDocumentCloseConfirmationState: { _ in rightPanelDocumentState },
            shouldBypassConfirmation: bypassesConfirmation,
            confirmStopAndClose: confirmStopAndClose ?? { _, _ in
                XCTFail("Unexpected confirmation")
                return false
            },
            confirmWorkspaceClose: confirmWorkspaceClose ?? { _, _ in
                XCTFail("Unexpected workspace confirmation")
                return false
            },
            presentRefusal: presentRefusal ?? { _, _ in },
            taskSpaceCloseAsker: taskSpaceCloseAsker
        )
        return Fixture(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            controller: controller,
            workspaceID: workspace.id,
            agentTabID: agentTabID,
            agentPanelID: agentPanelID
        )
    }
}
