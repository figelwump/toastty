@testable import ToasttyApp
import CoreState
import Foundation
import RemoteProtocol
import XCTest

@MainActor
final class SessionExitControllerTests: XCTestCase {
    // Failure modes: an exit typed over a draft or a queued phone message, an
    // exit sent for a turn that did not complete or into a newer turn, a
    // second exit for one request, an agent without a verified exit command,
    // and an unattended pane close that hides the visible tab, removes a
    // workspace, ends a crashed agent's evidence, or takes a pane back in use.

    // MARK: - Exit after the turn

    func testCompletedTurnTypesTheNativeExitOnce() async throws {
        let fixture = try makeFixture()
        fixture.startAgent(.codex)
        fixture.setStatus(.working, at: fixture.turnStart)
        try fixture.controller.armExitAfterTurn(panelID: fixture.agentPanelID, expectedSessionID: fixture.sessionID)
        // Arming again in the same turn keeps one request.
        try fixture.controller.armExitAfterTurn(panelID: fixture.agentPanelID, expectedSessionID: fixture.sessionID)

        fixture.setStatus(.ready)
        try await waitUntil { fixture.sent.count == 1 }
        XCTAssertEqual(fixture.sent.first?.text, "/exit")
        XCTAssertEqual(fixture.sent.first?.panelID, fixture.agentPanelID)

        // The request covered one turn only.
        fixture.setStatus(.working)
        fixture.setStatus(.ready)
        try await settle()
        XCTAssertEqual(fixture.sent.count, 1)
    }

    func testArmingNeedsTheExpectedSessionInARunningTurnOfAKnownAgent() throws {
        let fixture = try makeFixture()
        fixture.startAgent(.claude)
        fixture.setStatus(.working)
        fixture.setStatus(.ready)
        XCTAssertThrowsError(
            try fixture.controller.armExitAfterTurn(panelID: fixture.agentPanelID, expectedSessionID: fixture.sessionID)
        ) { XCTAssertEqual($0 as? SessionExitController.ArmError, .noRunningTurn) }

        fixture.setStatus(.working)
        XCTAssertThrowsError(
            try fixture.controller.armExitAfterTurn(panelID: fixture.agentPanelID, expectedSessionID: "someone-else")
        ) { XCTAssertEqual($0 as? SessionExitController.ArmError, .sessionNotInPanel) }

        // A task space is marked done instead of exiting its session.
        let taskSpace = try makeFixture()
        XCTAssertTrue(taskSpace.store.send(.createWorkspace(windowID: taskSpace.store.state.windows[0].id, title: "Parent", activate: false)))
        let parentID = try XCTUnwrap(taskSpace.store.state.windows[0].workspaceIDs.last)
        XCTAssertTrue(taskSpace.store.send(.setWorkspaceParent(
            workspaceID: taskSpace.workspaceID, parentWorkspaceID: parentID, spawningSessionID: nil
        )))
        taskSpace.startAgent(.codex)
        taskSpace.setStatus(.working)
        XCTAssertThrowsError(
            try taskSpace.controller.armExitAfterTurn(panelID: taskSpace.agentPanelID, expectedSessionID: taskSpace.sessionID)
        ) { XCTAssertEqual($0 as? SessionExitController.ArmError, .sessionInTaskSpace) }

        let other = try makeFixture()
        other.startAgent(.cursor)
        other.setStatus(.working)
        XCTAssertThrowsError(
            try other.controller.armExitAfterTurn(panelID: other.agentPanelID, expectedSessionID: other.sessionID)
        ) { XCTAssertEqual($0 as? SessionExitController.ArmError, .unsupportedAgent(.cursor)) }
    }

    func testInputDuringTheTurnKeepsTheAgentRunning() async throws {
        // Typing before the turn, such as the prompt itself, does not count.
        let typedBefore = try makeFixture()
        typedBefore.startAgent(.claude)
        typedBefore.sessionRuntimeStore.noteLocalInputForActiveSession(panelID: typedBefore.agentPanelID)
        typedBefore.setStatus(.working, at: Date().addingTimeInterval(1))
        try typedBefore.controller.armExitAfterTurn(panelID: typedBefore.agentPanelID, expectedSessionID: typedBefore.sessionID)
        typedBefore.setStatus(.ready)
        try await waitUntil { typedBefore.sent.count == 1 }

        let typedDuring = try makeFixture()
        typedDuring.startAgent(.claude)
        typedDuring.setStatus(.working, at: typedDuring.turnStart)
        try typedDuring.controller.armExitAfterTurn(panelID: typedDuring.agentPanelID, expectedSessionID: typedDuring.sessionID)
        typedDuring.sessionRuntimeStore.noteLocalInputForActiveSession(panelID: typedDuring.agentPanelID)
        typedDuring.setStatus(.ready)
        try await settle()
        XCTAssertTrue(typedDuring.sent.isEmpty)
        XCTAssertTrue(typedDuring.controller.armedExitsBySessionID.isEmpty)

        let phone = try makeFixture()
        let probe = RemoteInputProbe(hasInput: true)
        phone.controller.remoteInputProbe = probe
        phone.startAgent(.codex)
        phone.setStatus(.working, at: phone.turnStart)
        try phone.controller.armExitAfterTurn(panelID: phone.agentPanelID, expectedSessionID: phone.sessionID)
        phone.setStatus(.ready)
        try await settle()
        XCTAssertTrue(phone.sent.isEmpty)
        XCTAssertEqual(probe.askedSince, [phone.turnStart])
    }

    func testATurnThatDoesNotCompleteOrAStopDisarms() async throws {
        let interrupted = try makeFixture()
        interrupted.startAgent(.claude)
        interrupted.setStatus(.working)
        try interrupted.controller.armExitAfterTurn(panelID: interrupted.agentPanelID, expectedSessionID: interrupted.sessionID)
        interrupted.setStatus(.idle)
        interrupted.setStatus(.working)
        interrupted.setStatus(.ready)
        try await settle()
        XCTAssertTrue(interrupted.sent.isEmpty)

        let failed = try makeFixture()
        failed.startAgent(.codex)
        failed.setStatus(.working)
        try failed.controller.armExitAfterTurn(panelID: failed.agentPanelID, expectedSessionID: failed.sessionID)
        failed.setStatus(.error)
        XCTAssertTrue(failed.controller.armedExitsBySessionID.isEmpty)

        let stopped = try makeFixture()
        stopped.startAgent(.codex)
        stopped.setStatus(.working)
        try stopped.controller.armExitAfterTurn(panelID: stopped.agentPanelID, expectedSessionID: stopped.sessionID)
        stopped.sessionRuntimeStore.stopSessionForPanel(panelID: stopped.agentPanelID, reason: .explicit, at: Date())
        XCTAssertTrue(stopped.controller.armedExitsBySessionID.isEmpty)
    }

    func testANewTurnOrAnAbandonedTurnBeforeDeliveryKeepsTheAgentRunning() async throws {
        // A newer turn that starts, and even completes, while the exit waits.
        let newer = try makeFixture()
        newer.startAgent(.claude)
        newer.setStatus(.working)
        try newer.controller.armExitAfterTurn(panelID: newer.agentPanelID, expectedSessionID: newer.sessionID)
        newer.setStatus(.ready)
        newer.setStatus(.working)
        newer.setStatus(.ready)

        // An error right after the completion, while the exit waits.
        let failed = try makeFixture()
        failed.startAgent(.codex)
        failed.setStatus(.working)
        try failed.controller.armExitAfterTurn(panelID: failed.agentPanelID, expectedSessionID: failed.sessionID)
        failed.setStatus(.ready)
        failed.setStatus(.error)

        try await settle()
        XCTAssertTrue(newer.sent.isEmpty)
        XCTAssertTrue(failed.sent.isEmpty)
    }

    func testDeliveryRechecksTheSessionRightBeforeTyping() throws {
        let fixture = try makeFixture()
        fixture.startAgent(.claude)
        fixture.setStatus(.working)
        let armed = try fixture.controller.armExitAfterTurn(panelID: fixture.agentPanelID, expectedSessionID: fixture.sessionID)
        fixture.sessionRuntimeStore.stopSessionForPanel(panelID: fixture.agentPanelID, reason: .explicit, at: Date())

        XCTAssertEqual(fixture.controller.deliverArmedExit(sessionID: fixture.sessionID, token: armed.token), .sessionGone)
        XCTAssertTrue(fixture.sent.isEmpty)
    }

    // Failure modes for unread retirement: arming without delivery, failed or
    // superseded exits, generic notices sharing the bit, and a replacement
    // session acquiring that panel after the exit.
    func testDeliveredCleanSelfExitSkipsCompletionPreservesUnreadAndStillFindsChild() async throws {
        let fixture = try makeFixture()
        try fixture.completeArmedTurn()
        try await waitUntil { fixture.sent.count == 1 }
        XCTAssertTrue(fixture.isUnread)
        fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
        XCTAssertTrue(fixture.isUnread)
        XCTAssertNotNil(fixture.workspace.tab(id: fixture.agentTabID))
        XCTAssertNil(fixture.nextTarget)

        XCTAssertTrue(fixture.store.send(.createWorkspaceTab(workspaceID: fixture.workspaceID, seed: nil, activate: false)))
        let childTab = try XCTUnwrap(fixture.workspace.orderedTabs.last)
        let childPanel = try XCTUnwrap(childTab.focusedPanelID)
        fixture.startSession("child", panelID: childPanel)
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: "child", status: SessionStatus(kind: .working, summary: "Child working"), at: Date()
        )
        XCTAssertEqual(fixture.nextTarget?.panelID, childPanel)
        fixture.genericNotice()
        XCTAssertEqual(fixture.nextTarget?.panelID, fixture.agentPanelID)
    }

    func testArmingOrOrdinaryCompletionDoesNotRetireUnreadOnManualExit() async throws {
        for armed in [false, true] {
            let fixture = try makeFixture()
            fixture.startAgent(.codex)
            fixture.setStatus(.working)
            if armed {
                try fixture.controller.armExitAfterTurn(panelID: fixture.agentPanelID, expectedSessionID: fixture.sessionID)
            }
            fixture.setStatus(.ready)
            XCTAssertTrue(fixture.isUnread)
            // Stop before the scheduled delivery gets a chance to run.
            fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
            try await settle()
            XCTAssertTrue(fixture.sent.isEmpty)
            XCTAssertTrue(fixture.isUnread)
            XCTAssertEqual(fixture.nextTarget?.panelID, fixture.agentPanelID)
        }
    }

    func testSkippedOrFailedDeliveryPreservesCompletion() async throws {
        for skip in ["local", "remote", "delivery"] {
            let fixture = try makeFixture()
            let probe = RemoteInputProbe(hasInput: skip == "remote")
            fixture.controller.remoteInputProbe = probe
            fixture.deliverySucceeds = skip != "delivery"
            fixture.startAgent(.codex)
            fixture.setStatus(.working, at: fixture.turnStart)
            try fixture.controller.armExitAfterTurn(panelID: fixture.agentPanelID, expectedSessionID: fixture.sessionID)
            if skip == "local" {
                fixture.sessionRuntimeStore.noteLocalInputForActiveSession(panelID: fixture.agentPanelID)
            }
            fixture.setStatus(.ready)
            try await waitUntil { fixture.controller.armedExitsBySessionID.isEmpty }
            fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
            try await settle()
            XCTAssertTrue(fixture.isUnread, skip)
            XCTAssertEqual(fixture.nextTarget?.panelID, fixture.agentPanelID)
        }
    }

    func testOnlyConfirmedCleanStopRetiresDeliveredExit() async throws {
        for reason: ManagedSessionStopReason in [.explicit, .idleAtPrompt, .ghosttyCommandFinished(exitCode: nil), .ghosttyCommandFinished(exitCode: 1)] {
            let fixture = try makeFixture()
            try fixture.completeArmedTurn()
            try await waitUntil { fixture.sent.count == 1 }
            fixture.sessionRuntimeStore.stopSessionForPanel(panelID: fixture.agentPanelID, reason: reason, at: Date())
            try await settle()
            XCTAssertTrue(fixture.isUnread, reason.code)
            XCTAssertEqual(fixture.nextTarget?.panelID, fixture.agentPanelID)
        }
    }

    func testGenericUnreadBeforeCompletionBeforeExitOrAfterExitStaysReachable() async throws {
        for timing in ["before", "after", "stopped"] {
            let fixture = try makeFixture()
            fixture.startAgent(.codex)
            fixture.setStatus(.working)
            try fixture.controller.armExitAfterTurn(panelID: fixture.agentPanelID, expectedSessionID: fixture.sessionID)
            if timing == "before" { fixture.genericNotice() }
            fixture.setStatus(.ready)
            try await waitUntil { fixture.sent.count == 1 }
            if timing == "after" { fixture.genericNotice() }
            fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
            if timing == "stopped" { fixture.genericNotice() }
            try await settle()
            XCTAssertTrue(fixture.isUnread, timing)
            XCTAssertEqual(fixture.nextTarget?.panelID, fixture.agentPanelID)
        }
    }

    func testReadCompletionCannotClearANewerGenericNotice() async throws {
        for newNotice in [false, true] {
            let fixture = try makeFixture()
            try fixture.completeArmedTurn()
            try await waitUntil { fixture.sent.count == 1 }
            XCTAssertTrue(fixture.store.send(.markPanelNotificationsRead(workspaceID: fixture.workspaceID, panelID: fixture.agentPanelID)))
            if newNotice { fixture.genericNotice() }
            fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
            try await settle()
            XCTAssertEqual(fixture.isUnread, newNotice)
            XCTAssertEqual(fixture.nextTarget?.panelID, newNotice ? fixture.agentPanelID : nil)
        }
    }

    func testUnreadFromBeforeBindingIsPreservedAndReadingAllowsLaterRetirement() async throws {
        let fixture = try makeFixture()
        fixture.sessionRuntimeStore.unbind()
        fixture.genericNotice()
        fixture.sessionRuntimeStore.bind(store: fixture.store)
        try fixture.completeArmedTurn()
        try await waitUntil { fixture.sent.count == 1 }
        fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
        try await settle()
        XCTAssertTrue(fixture.isUnread)

        XCTAssertTrue(fixture.store.send(.markPanelNotificationsRead(workspaceID: fixture.workspaceID, panelID: fixture.agentPanelID)))
        try fixture.completeArmedTurn()
        try await waitUntil { fixture.sent.count == 2 }
        fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
        XCTAssertTrue(fixture.isUnread)
        XCTAssertNil(fixture.nextTarget)
    }

    func testInputAfterExitDeliveryPreservesUnreadOnLaterCleanExit() async throws {
        for remote in [false, true] {
            let fixture = try makeFixture()
            let probe = RemoteInputProbe(hasInput: false)
            fixture.controller.remoteInputProbe = probe
            try fixture.completeArmedTurn()
            try await waitUntil { fixture.sent.count == 1 }
            if remote {
                probe.hasInput = true
            } else {
                fixture.sessionRuntimeStore.noteLocalInputForActiveSession(panelID: fixture.agentPanelID)
            }
            fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
            try await settle()
            XCTAssertTrue(fixture.isUnread)
            XCTAssertEqual(fixture.nextTarget?.panelID, fixture.agentPanelID)
        }
    }

    func testStateReplacementOrAnotherSessionNoticePreventsRetirement() async throws {
        for replacement in [false, true] {
            let fixture = try makeFixture()
            try fixture.completeArmedTurn()
            try await waitUntil { fixture.sent.count == 1 }
            fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
            if replacement {
                fixture.store.replaceState(fixture.store.state)
            } else {
                XCTAssertTrue(fixture.store.send(.recordDesktopNotification(
                    workspaceID: fixture.workspaceID, panelID: fixture.agentPanelID, sessionID: "another-session"
                )))
            }
            try await settle()
            XCTAssertTrue(fixture.isUnread)
            XCTAssertEqual(fixture.nextTarget?.panelID, fixture.agentPanelID)
        }
    }

    func testUnreadFromAnEarlierTurnRemainsANavigationTarget() async throws {
        let fixture = try makeFixture()
        fixture.startAgent(.codex)
        fixture.setStatus(.working)
        fixture.setStatus(.error)
        XCTAssertTrue(fixture.isUnread)
        fixture.setStatus(.working)
        try fixture.controller.armExitAfterTurn(panelID: fixture.agentPanelID, expectedSessionID: fixture.sessionID)
        fixture.setStatus(.ready)
        try await waitUntil { fixture.sent.count == 1 }
        fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
        XCTAssertTrue(fixture.isUnread)
        XCTAssertEqual(fixture.nextTarget?.panelID, fixture.agentPanelID)
    }

    func testMovingARetiredPanelRestoresNavigationEligibility() async throws {
        let fixture = try makeFixture(addsSecondTab: false, addsSecondWorkspace: true)
        try fixture.completeArmedTurn()
        try await waitUntil { fixture.sent.count == 1 }
        fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
        XCTAssertNil(fixture.nextTarget)
        let destination = try XCTUnwrap(fixture.store.selectedWorkspace)
        XCTAssertNotEqual(destination.id, fixture.workspaceID)
        XCTAssertTrue(fixture.store.send(.movePanelToWorkspace(
            panelID: fixture.agentPanelID, targetWorkspaceID: destination.id, targetSlotID: nil
        )))
        // Moving focuses the moved panel. Navigate from the existing pane.
        XCTAssertTrue(fixture.store.send(.focusPanel(
            workspaceID: destination.id, panelID: try XCTUnwrap(destination.focusedPanelID)
        )))
        XCTAssertTrue(fixture.store.state.workspacesByID[destination.id]?.unreadPanelIDs.contains(fixture.agentPanelID) == true)
        XCTAssertEqual(fixture.nextTarget?.panelID, fixture.agentPanelID)
    }

    func testNewTurnOrErrorAfterDeliveryKeepsUnread() async throws {
        for nextKind: SessionStatusKind in [.working, .error] {
            let fixture = try makeFixture()
            try fixture.completeArmedTurn()
            try await waitUntil { fixture.sent.count == 1 }
            fixture.setStatus(nextKind)
            if nextKind == .working { fixture.setStatus(.ready) }
            fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
            try await settle()
            XCTAssertTrue(fixture.isUnread)
            XCTAssertEqual(fixture.nextTarget?.panelID, fixture.agentPanelID)
        }
    }

    func testReplacementSessionKeepsItsUnreadEvenIfItAlsoStops() async throws {
        for replacementStops in [false, true] {
            let fixture = try makeFixture()
            try fixture.completeArmedTurn()
            try await waitUntil { fixture.sent.count == 1 }
            fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
            fixture.startSession("replacement", panelID: fixture.agentPanelID)
            fixture.sessionRuntimeStore.updateStatus(sessionID: "replacement", status: SessionStatus(kind: .working, summary: "Working"), at: Date())
            fixture.sessionRuntimeStore.updateStatus(sessionID: "replacement", status: SessionStatus(kind: .ready, summary: "Replacement reply"), at: Date())
            if replacementStops {
                fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
            }
            try await settle()
            XCTAssertTrue(fixture.isUnread)
            XCTAssertEqual(fixture.nextTarget?.panelID, fixture.agentPanelID)
        }
    }

    // MARK: - Clean exit closes the pane

    func testACleanExitClosesThePhoneStartedBackgroundTab() async throws {
        let fixture = try makeFixture()
        fixture.startAgent(.claude)
        fixture.controller.markClosesPaneOnCleanExit(sessionID: fixture.sessionID)
        let selectedTab = fixture.selectedTabID

        fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
        try await waitUntil { fixture.workspace.tab(id: fixture.agentTabID) == nil }
        XCTAssertEqual(fixture.selectedTabID, selectedTab)
    }

    func testAPaneStaysWhenTheExitWasNotCleanOrTheTabWasNotMadeForTheSession() async throws {
        let crashed = try makeFixture()
        crashed.startAgent(.claude)
        crashed.controller.markClosesPaneOnCleanExit(sessionID: crashed.sessionID)
        crashed.sessionRuntimeStore.finishCommand(panelID: crashed.agentPanelID, exitCode: 1)

        let unmarked = try makeFixture()
        unmarked.startAgent(.claude)
        unmarked.sessionRuntimeStore.finishCommand(panelID: unmarked.agentPanelID, exitCode: 0)

        try await settle()
        XCTAssertNotNil(crashed.workspace.tab(id: crashed.agentTabID))
        XCTAssertNotNil(unmarked.workspace.tab(id: unmarked.agentTabID))
        XCTAssertTrue(crashed.controller.closesPaneOnCleanExitSessionIDs.isEmpty)
    }

    func testAnUnattendedCloseNeverHidesTheVisibleTabOrRemovesAWorkspace() async throws {
        let visible = try makeFixture(addsSecondTab: false, addsBackgroundTab: true)
        visible.startAgent(.codex)
        visible.controller.markClosesPaneOnCleanExit(sessionID: visible.sessionID)
        visible.sessionRuntimeStore.finishCommand(panelID: visible.agentPanelID, exitCode: 0)

        // Bypassed prompts let a person close a workspace without asking,
        // but never an unattended close.
        let onlyTab = try makeFixture(addsSecondTab: false, addsSecondWorkspace: true, bypassesConfirmation: true)
        onlyTab.startAgent(.codex)
        onlyTab.controller.markClosesPaneOnCleanExit(sessionID: onlyTab.sessionID)
        onlyTab.sessionRuntimeStore.finishCommand(panelID: onlyTab.agentPanelID, exitCode: 0)

        try await settle()
        XCTAssertNotNil(visible.workspace.tab(id: visible.agentTabID))
        XCTAssertNotNil(onlyTab.store.state.workspacesByID[onlyTab.workspaceID])
    }

    func testAPaneInUseAgainStays() throws {
        let typed = try makeFixture()
        typed.startAgent(.claude)
        let stoppedAt = Date().addingTimeInterval(-1)
        typed.sessionRuntimeStore.stopSessionForPanel(panelID: typed.agentPanelID, reason: .explicit, at: stoppedAt)
        typed.sessionRuntimeStore.noteLocalInputForActiveSession(panelID: typed.agentPanelID)
        XCTAssertNil(typed.controller.closeExitedPane(sessionID: typed.sessionID, panelID: typed.agentPanelID, stoppedAt: stoppedAt))
        XCTAssertNotNil(typed.workspace.tab(id: typed.agentTabID))

        let relaunched = try makeFixture()
        relaunched.startAgent(.claude)
        XCTAssertNil(relaunched.controller.closeExitedPane(sessionID: "earlier", panelID: relaunched.agentPanelID, stoppedAt: Date()))
        XCTAssertNotNil(relaunched.workspace.tab(id: relaunched.agentTabID))
    }

    func testAReplacementThatAlsoStoppedKeepsItsPane() async throws {
        let fixture = try makeFixture()
        fixture.startAgent(.claude)
        fixture.controller.markClosesPaneOnCleanExit(sessionID: fixture.sessionID)
        fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 0)
        // Before the scheduled close runs, another agent starts in the pane and crashes.
        fixture.sessionRuntimeStore.startSession(
            sessionID: "replacement", agent: .codex, panelID: fixture.agentPanelID,
            windowID: fixture.store.state.windows[0].id, workspaceID: fixture.workspaceID,
            codexStatusTrackingSource: .externallyReported, cwd: "/repo", repoRoot: "/repo",
            at: Date().addingTimeInterval(1)
        )
        fixture.sessionRuntimeStore.finishCommand(panelID: fixture.agentPanelID, exitCode: 1)

        try await settle()
        XCTAssertNotNil(fixture.workspace.tab(id: fixture.agentTabID))
    }

    // MARK: - Fixture

    private final class RemoteInputProbe: SessionRemoteInputProbe {
        var hasInput: Bool
        var askedSince: [Date] = []

        init(hasInput: Bool) {
            self.hasInput = hasInput
        }

        func hasRemoteInput(panelID _: UUID, since date: Date) -> Bool {
            askedSince.append(date)
            return hasInput
        }
    }

    @MainActor
    private final class Fixture {
        let store: AppStore
        let sessionRuntimeStore: SessionRuntimeStore
        var controller: SessionExitController!
        let workspaceID: UUID
        let agentTabID: UUID
        let agentPanelID: UUID
        let sessionID = "exit-test-session"
        let turnStart = Date().addingTimeInterval(-30)
        var sent: [(text: String, panelID: UUID)] = []
        var deliverySucceeds = true

        init(store: AppStore, sessionRuntimeStore: SessionRuntimeStore, workspaceID: UUID, agentTabID: UUID, agentPanelID: UUID) {
            self.store = store
            self.sessionRuntimeStore = sessionRuntimeStore
            self.workspaceID = workspaceID
            self.agentTabID = agentTabID
            self.agentPanelID = agentPanelID
        }

        var workspace: WorkspaceState { store.state.workspacesByID[workspaceID]! }
        var selectedTabID: UUID? { workspace.resolvedSelectedTabID }

        var isUnread: Bool { workspace.tab(id: agentTabID)?.unreadPanelIDs.contains(agentPanelID) == true }
        var nextTarget: PanelNavigationTarget? {
            store.nextUnreadOrActivePanelTargetFromCommand(preferredWindowID: store.state.windows[0].id, sessionRuntimeStore: sessionRuntimeStore)
        }

        func genericNotice() {
            XCTAssertTrue(store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: agentPanelID)))
        }

        func completeArmedTurn() throws {
            startAgent(.codex)
            setStatus(.working)
            try controller.armExitAfterTurn(panelID: agentPanelID, expectedSessionID: sessionID)
            setStatus(.ready)
        }

        func startSession(_ id: String, panelID: UUID) {
            sessionRuntimeStore.startSession(
                sessionID: id, agent: .codex, panelID: panelID,
                windowID: store.state.windows[0].id, workspaceID: workspaceID,
                usesSessionStatusNotifications: true,
                codexStatusTrackingSource: .externallyReported, cwd: "/repo", repoRoot: "/repo", at: Date()
            )
        }

        func startAgent(_ agent: AgentKind) {
            sessionRuntimeStore.startSession(
                sessionID: sessionID, agent: agent, panelID: agentPanelID,
                windowID: store.state.windows[0].id, workspaceID: workspaceID,
                usesSessionStatusNotifications: true,
                codexStatusTrackingSource: .externallyReported, cwd: "/repo", repoRoot: "/repo", at: Date()
            )
        }

        func setStatus(_ kind: SessionStatusKind, at date: Date = Date()) {
            sessionRuntimeStore.updateStatus(
                sessionID: sessionID, status: SessionStatus(kind: kind, summary: "status"), at: date
            )
        }
    }

    /// The agent runs in the workspace's first tab. With `addsSecondTab`, a
    /// second tab is created and selected, so the agent's tab is in the
    /// background, as for a session started from the phone. With
    /// `addsBackgroundTab`, a second tab is added without selecting it.
    private func makeFixture(
        addsSecondTab: Bool = true,
        addsBackgroundTab: Bool = false,
        addsSecondWorkspace: Bool = false,
        bypassesConfirmation: Bool = false
    ) throws -> Fixture {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        let agentTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let agentPanelID = try XCTUnwrap(workspace.focusedPanelID)
        if addsSecondTab || addsBackgroundTab {
            XCTAssertTrue(store.send(.createWorkspaceTab(workspaceID: workspace.id, seed: nil, activate: addsSecondTab)))
        }
        if addsSecondWorkspace {
            XCTAssertTrue(store.send(.createWorkspace(windowID: store.state.windows[0].id, title: "Other", activate: true)))
        }
        let sessionRuntimeStore = SessionRuntimeStore(
            sendSessionStatusNotification: { _, _, _, _, _ in },
            isApplicationActive: { false }
        )
        sessionRuntimeStore.bind(store: store)
        let idle = TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        let closeController = SessionCloseController(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: FocusedPanelCommandController(
                store: store,
                runtimeRegistry: TerminalRuntimeRegistry(),
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
                shouldConfirmClose: true,
                terminalCloseAssessmentProvider: { _ in idle }
            ),
            terminalCloseAssessment: { _ in idle },
            localDocumentCloseConfirmationState: { _ in nil },
            shouldBypassConfirmation: bypassesConfirmation,
            confirmStopAndClose: { _, _ in false },
            confirmWorkspaceClose: { _, _ in false },
            presentRefusal: { _, _ in }
        )
        let fixture = Fixture(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            workspaceID: workspace.id,
            agentTabID: agentTabID,
            agentPanelID: agentPanelID
        )
        fixture.controller = SessionExitController(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            sessionCloseController: closeController,
            sendText: { [weak fixture] text, panelID in
                // TerminalRuntimeRegistry.sendText records this synchronously.
                fixture?.sessionRuntimeStore.noteLocalInputForActiveSession(panelID: panelID)
                fixture?.sent.append((text, panelID))
                return fixture?.deliverySucceeds == true
            },
            promptSettleDelay: .zero
        )
        sessionRuntimeStore.sessionExitController = fixture.controller
        return fixture
    }

    /// Lets scheduled main-actor work run.
    private func settle() async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met in time", file: file, line: line)
    }
}

private extension SessionRuntimeStore {
    /// The terminal reports that the agent's command ended.
    func finishCommand(panelID: UUID, exitCode: Int?) {
        _ = handleCommandFinished(panelID: panelID, exitCode: exitCode, at: Date())
    }
}
