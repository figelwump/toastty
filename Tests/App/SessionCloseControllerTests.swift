@testable import ToasttyApp
import CoreState
import Foundation
import RemoteProtocol
import XCTest

@MainActor
final class SessionCloseControllerTests: XCTestCase {
    // Failure modes: a busy or just-launched agent closed silently, a finished
    // agent still asking, a background close switching the visible tab, a
    // workspace's last pane closed (which removes the workspace), and a
    // missing terminal assessment treated as idle.

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

    func testTheLastPaneInAWorkspaceIsRefusedEvenWhenStopping() throws {
        let fixture = try makeFixture(addsSecondTab: false)
        fixture.startAgent()
        fixture.setStatus(.ready)

        XCTAssertEqual(
            fixture.controller.closeSession(panelID: fixture.agentPanelID, stopIfBusy: true, source: .command("test")),
            .lastPaneInWorkspace
        )
        XCTAssertNotNil(fixture.store.state.workspacesByID[fixture.workspaceID])
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

    func testInteractiveCloseExplainsALastPaneRefusal() throws {
        var refusedTitles: [String] = []
        let fixture = try makeFixture(addsSecondTab: false, presentRefusal: { title, _ in refusedTitles.append(title) })

        fixture.controller.closeSessionInteractively(panelID: fixture.agentPanelID, sessionTitle: "Fix login")

        XCTAssertEqual(refusedTitles, ["Fix login"])
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
        terminalAssessment: TerminalCloseConfirmationAssessment? = TerminalCloseConfirmationAssessment(
            requiresConfirmation: true, runningCommand: "claude"
        ),
        rightPanelDocumentState: LocalDocumentCloseConfirmationState? = nil,
        confirmStopAndClose: (@MainActor (String, String?) -> Bool)? = nil,
        presentRefusal: (@MainActor (String, String) -> Void)? = nil
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
            shouldBypassConfirmation: false,
            confirmStopAndClose: confirmStopAndClose ?? { _, _ in
                XCTFail("Unexpected confirmation")
                return false
            },
            presentRefusal: presentRefusal ?? { _, _ in }
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
