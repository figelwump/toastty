@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreNavigationHistoryTests: AppStoreCommandTestCase {
    func testWorkspaceTabAndSplitVisitsRestoreTheContainingSelection() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        let a = try focusedPanel(in: store)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        let b = try focusedPanel(in: store)
        let firstTabID = try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID]?.resolvedSelectedTabID)
        XCTAssertTrue(store.sendNavigation(.createWorkspaceTab(workspaceID: fixture.workspaceID, seed: nil)))
        let c = try focusedPanel(in: store)
        let secondTabID = try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID]?.resolvedSelectedTabID)
        XCTAssertTrue(store.sendNavigation(.createWorkspace(windowID: fixture.windowID, title: "Other", activate: true)))
        let d = try focusedPanel(in: store)

        XCTAssertEqual(store.navigationHistory.entries, [a, b, c, d])
        XCTAssertTrue(store.navigateBack())
        XCTAssertEqual(try focusedPanel(in: store), c)
        XCTAssertEqual(store.state.selectedWorkspaceID(in: fixture.windowID), fixture.workspaceID)
        XCTAssertEqual(store.state.workspacesByID[fixture.workspaceID]?.resolvedSelectedTabID, secondTabID)
        XCTAssertTrue(store.navigateBack())
        XCTAssertEqual(try focusedPanel(in: store), b)
        XCTAssertEqual(store.state.workspacesByID[fixture.workspaceID]?.resolvedSelectedTabID, firstTabID)
        XCTAssertTrue(store.navigateBack())
        XCTAssertEqual(try focusedPanel(in: store), a)
        XCTAssertFalse(store.canNavigateBack)
        XCTAssertTrue(store.navigateForward())
        XCTAssertEqual(try focusedPanel(in: store), b)
        XCTAssertEqual(store.navigationHistory.entries, [a, b, c, d])
    }

    func testNestedNavigationRecordsOnlyFinalPanel() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        let a = try focusedPanel(in: store)

        store.performNavigation {
            XCTAssertTrue(store.sendNavigation(.createWorkspaceTab(workspaceID: fixture.workspaceID, seed: nil)))
            XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        }

        let destination = try focusedPanel(in: store)
        XCTAssertEqual(store.navigationHistory.entries, [a, destination])
        XCTAssertTrue(store.navigateBack())
        XCTAssertEqual(try focusedPanel(in: store), a)
    }

    func testAuxiliaryPanelHistoryRevealsItsOwningTabAndRestoresMainFocus() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        let mainPanel = try focusedPanel(in: store)
        let mainTabID = try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID]?.resolvedSelectedTabID)
        let auxiliaryPanel = UUID()
        XCTAssertTrue(store.sendNavigation(.createRightAuxWebPanel(
            workspaceID: fixture.workspaceID,
            tabID: mainTabID,
            panelID: auxiliaryPanel,
            panel: WebPanelState(definition: .browser),
            activation: .focus
        )))
        XCTAssertTrue(store.sendNavigation(.createWorkspaceTab(workspaceID: fixture.workspaceID, seed: nil)))
        let otherTabPanel = try focusedPanel(in: store)

        XCTAssertEqual(store.navigationHistory.entries, [mainPanel, auxiliaryPanel, otherTabPanel])
        XCTAssertTrue(store.navigateBack())
        let workspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID])
        XCTAssertEqual(workspace.resolvedSelectedTabID, mainTabID)
        XCTAssertTrue(workspace.rightAuxPanel.isVisible)
        XCTAssertEqual(workspace.rightAuxPanel.focusedPanelID, auxiliaryPanel)
        XCTAssertEqual(try focusedPanel(in: store), auxiliaryPanel)
        XCTAssertTrue(store.navigateBack())
        XCTAssertEqual(try focusedPanel(in: store), mainPanel)
        XCTAssertNil(store.state.workspacesByID[fixture.workspaceID]?.rightAuxPanel.focusedPanelID)
    }

    func testCrossWindowTraversalActivatesDestinationWithoutRecordingAnotherVisit() throws {
        let fixture = try twoWindowFixture()
        var activatedWindows: [UUID] = []
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false, windowActivationHandler: {
            activatedWindows.append($0)
        })

        XCTAssertTrue(store.focusPanel(containing: fixture.secondPanelID))
        XCTAssertEqual(activatedWindows, [fixture.secondWindowID])
        XCTAssertTrue(store.navigateBack())
        XCTAssertEqual(store.state.selectedWindowID, fixture.firstWindowID)
        XCTAssertEqual(try focusedPanel(in: store), fixture.firstPanelID)
        XCTAssertTrue(store.navigateForward())
        XCTAssertEqual(store.state.selectedWindowID, fixture.secondWindowID)
        XCTAssertEqual(activatedWindows, [fixture.secondWindowID, fixture.firstWindowID, fixture.secondWindowID])
        XCTAssertEqual(store.navigationHistory.entries, [fixture.firstPanelID, fixture.secondPanelID])
    }

    func testWindowNotificationBeforeActualClickStillRecordsPreviousLocation() throws {
        let fixture = try twoWindowFixture()
        let store = makeStore(state: fixture.state)

        XCTAssertTrue(store.send(.selectWindow(windowID: fixture.secondWindowID)))
        XCTAssertTrue(store.navigationHistory.entries.isEmpty)
        XCTAssertEqual(try focusedPanel(in: store), fixture.secondPanelID)
        XCTAssertTrue(store.focusPanel(containing: fixture.secondPanelID))

        XCTAssertEqual(store.navigationHistory.entries, [fixture.firstPanelID, fixture.secondPanelID])
        XCTAssertTrue(store.navigateBack())
        XCTAssertEqual(try focusedPanel(in: store), fixture.firstPanelID)
    }

    func testDelayedResponderRestorationCannotStealSelectionOrDestroyForwardHistory() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        let a = try focusedPanel(in: store)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        let b = try focusedPanel(in: store)
        XCTAssertTrue(store.navigateBack())
        let history = store.navigationHistory

        for _ in 0..<3 {
            XCTAssertFalse(store.focusPanel(containing: b, intent: .restoration))
            XCTAssertTrue(store.focusPanel(containing: a, intent: .restoration))
        }

        XCTAssertEqual(try focusedPanel(in: store), a)
        XCTAssertEqual(store.navigationHistory, history)
        XCTAssertTrue(store.canNavigateForward)
        XCTAssertTrue(store.navigateForward())
        XCTAssertEqual(try focusedPanel(in: store), b)
    }

    func testBackgroundCreationMetadataAndMaintenanceLeaveHistoryUnchanged() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        let a = try focusedPanel(in: store)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        let b = try focusedPanel(in: store)
        XCTAssertTrue(store.navigateBack())
        let history = store.navigationHistory

        XCTAssertTrue(store.send(.createWorkspace(windowID: fixture.windowID, title: "Background", activate: false)))
        XCTAssertTrue(store.send(.updateTerminalPanelMetadata(panelID: b, title: "Updated", cwd: "/tmp/updated")))
        store.performNavigation(intent: .restoration) {
            XCTAssertTrue(store.sendNavigation(.focusPanel(workspaceID: fixture.workspaceID, panelID: a)))
        }

        XCTAssertEqual(try focusedPanel(in: store), a)
        XCTAssertEqual(store.navigationHistory, history)
        XCTAssertTrue(store.canNavigateForward)
        XCTAssertTrue(store.navigationForwardHelp.contains("Updated"))
    }

    func testClosingCurrentPanelKeepsHistoryBoundaryAndBranchPreservesFallbackOrigin() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        let a = try focusedPanel(in: store)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        let b = try focusedPanel(in: store)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        let c = try focusedPanel(in: store)
        XCTAssertTrue(store.sendNavigation(.createWorkspace(windowID: fixture.windowID, title: "Other", activate: true)))
        let d = try focusedPanel(in: store)
        XCTAssertTrue(store.navigateBack())
        XCTAssertTrue(store.send(.closePanel(panelID: c)))
        XCTAssertTrue(store.send(.focusPanel(workspaceID: fixture.workspaceID, panelID: b)))

        XCTAssertEqual(store.navigationHistory.entries, [a, b, c, d])
        XCTAssertEqual(store.navigationHistory.cursor, 2)
        XCTAssertTrue(store.canNavigateBack)
        XCTAssertTrue(store.canNavigateForward)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .down)))
        let e = try focusedPanel(in: store)
        XCTAssertEqual(store.navigationHistory.entries, [a, b, c, b, e])
        XCTAssertFalse(store.canNavigateForward)
        XCTAssertTrue(store.navigateBack())
        XCTAssertEqual(try focusedPanel(in: store), b)
        XCTAssertTrue(store.navigateBack())
        XCTAssertEqual(try focusedPanel(in: store), a)
    }

    func testNoOpAndFailedSelectionPreserveForwardAndReplaceStateClearsHistory() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        let a = try focusedPanel(in: store)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        XCTAssertTrue(store.navigateBack())
        let history = store.navigationHistory

        XCTAssertTrue(store.focusPanel(containing: a))
        XCTAssertFalse(store.focusPanel(containing: UUID()))
        XCTAssertFalse(store.sendNavigation(.focusPanel(workspaceID: fixture.workspaceID, panelID: UUID())))
        XCTAssertFalse(store.navigateBack())
        XCTAssertEqual(store.navigationHistory, history)
        XCTAssertTrue(store.canNavigateForward)

        store.replaceState(fixture.state)
        XCTAssertTrue(store.navigationHistory.entries.isEmpty)
        XCTAssertNil(store.navigationHistory.cursor)
        XCTAssertFalse(store.canNavigateBack)
        XCTAssertFalse(store.canNavigateForward)
        XCTAssertEqual(store.navigationBackHelp, "Back")
        XCTAssertEqual(store.navigationForwardHelp, "Forward")
    }

    func testTraversalFollowsMovedPanelAndUpdatesDestinationHelp() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        let a = try focusedPanel(in: store)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        let b = try focusedPanel(in: store)
        XCTAssertTrue(store.send(.createWorkspace(windowID: fixture.windowID, title: "Moved destination", activate: false)))
        let otherWorkspaceID = try XCTUnwrap(store.state.windows.first?.workspaceIDs.first { $0 != fixture.workspaceID })
        XCTAssertTrue(store.send(.movePanelToWorkspace(panelID: a, targetWorkspaceID: otherWorkspaceID, targetSlotID: nil)))

        XCTAssertTrue(store.navigationBackHelp.contains("Moved destination"))
        XCTAssertTrue(store.navigateBack())
        XCTAssertEqual(store.state.selectedWorkspaceID(in: fixture.windowID), otherWorkspaceID)
        XCTAssertEqual(try focusedPanel(in: store), a)
        XCTAssertTrue(store.navigateForward())
        XCTAssertEqual(try focusedPanel(in: store), b)
    }

    func testTraversalPreservesFocusModeAndRevealsTheDestinationPanel() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        let a = try focusedPanel(in: store)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        let b = try focusedPanel(in: store)
        XCTAssertTrue(store.send(.toggleFocusedPanelMode(workspaceID: fixture.workspaceID)))

        XCTAssertTrue(store.navigateBack())
        let workspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID])
        XCTAssertTrue(workspace.focusedPanelModeActive)
        XCTAssertEqual(try focusedPanel(in: store), a)
        let rootID = try XCTUnwrap(workspace.effectiveFocusModeRootNodeID)
        XCTAssertNotNil(workspace.layoutTree.findSubtree(nodeID: rootID)?.slotContaining(panelID: a))
        XCTAssertTrue(store.navigateForward())
        XCTAssertEqual(try focusedPanel(in: store), b)
        XCTAssertTrue(try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID]).focusedPanelModeActive)
    }

    func testClosureUpdatesAvailabilityWithoutReopeningDeadPanel() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        let a = try focusedPanel(in: store)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        let b = try focusedPanel(in: store)
        XCTAssertTrue(store.navigateBack())
        XCTAssertTrue(store.canNavigateForward)

        XCTAssertTrue(store.send(.closePanel(panelID: b)))

        XCTAssertFalse(store.canNavigateForward)
        XCTAssertFalse(store.navigateForward())
        XCTAssertEqual(try focusedPanel(in: store), a)
        XCTAssertNil(store.state.workspaceSelection(containingPanelID: b))
        XCTAssertEqual(store.navigationForwardHelp, "Forward")
    }

    func testThrowingNavigationAfterMutationDoesNotRecordPartialVisit() throws {
        enum NavigationFailure: Error { case interrupted }
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        let initialPanel = try focusedPanel(in: store)

        XCTAssertThrowsError(try store.performNavigation {
            XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
            throw NavigationFailure.interrupted
        })

        let changedPanel = try focusedPanel(in: store)
        XCTAssertNotEqual(changedPanel, initialPanel)
        XCTAssertTrue(store.navigationHistory.entries.isEmpty)
        XCTAssertFalse(store.canNavigateBack)
        XCTAssertTrue(store.focusPanel(containing: initialPanel))
        XCTAssertEqual(store.navigationHistory.entries, [changedPanel, initialPanel])
    }

    func testStateReplacementInsideNavigationDoesNotRepopulateClearedHistory() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        XCTAssertFalse(store.navigationHistory.entries.isEmpty)

        store.performNavigation {
            store.replaceState(fixture.state)
        }

        XCTAssertTrue(store.navigationHistory.entries.isEmpty)
        XCTAssertNil(store.navigationHistory.cursor)
        XCTAssertFalse(store.canNavigateBack)
        XCTAssertFalse(store.canNavigateForward)
        XCTAssertEqual(try focusedPanel(in: store), fixture.state.workspacesByID[fixture.workspaceID]?.focusedPanelID)
    }

    func testHistoryTraversalInsideUserNavigationIsRejectedWithoutLosingForward() throws {
        let fixture = makeSingleWindowState(initialTerminalCWD: "/tmp")
        let store = makeStore(state: fixture.state)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        let middlePanel = try focusedPanel(in: store)
        XCTAssertTrue(store.sendNavigation(.splitFocusedSlotInDirection(workspaceID: fixture.workspaceID, direction: .right)))
        let lastPanel = try focusedPanel(in: store)
        XCTAssertTrue(store.navigateBack())
        let history = store.navigationHistory
        XCTAssertTrue(store.canNavigateBack)

        store.performNavigation {
            XCTAssertFalse(store.navigateBack())
        }

        XCTAssertEqual(try focusedPanel(in: store), middlePanel)
        XCTAssertEqual(store.navigationHistory, history)
        XCTAssertTrue(store.canNavigateForward)
        XCTAssertTrue(store.navigateForward())
        XCTAssertEqual(try focusedPanel(in: store), lastPanel)
    }

    func testBackgroundAndFailedRequestsAfterWindowNotificationPreserveOriginForActualClick() throws {
        let fixture = try twoWindowFixture()
        let store = makeStore(state: fixture.state)
        XCTAssertTrue(store.send(.selectWindow(windowID: fixture.secondWindowID)))
        let workspaceID = try XCTUnwrap(store.state.selectedWorkspaceID(in: fixture.secondWindowID))

        XCTAssertTrue(store.sendNavigation(.createWorkspace(
            windowID: fixture.secondWindowID, title: "Background", activate: false
        )))
        XCTAssertFalse(store.sendNavigation(.focusPanel(workspaceID: workspaceID, panelID: UUID())))
        XCTAssertTrue(store.navigationHistory.entries.isEmpty)
        XCTAssertEqual(try focusedPanel(in: store), fixture.secondPanelID)

        XCTAssertTrue(store.sendNavigation(.focusPanel(workspaceID: workspaceID, panelID: fixture.secondPanelID)))

        XCTAssertEqual(store.navigationHistory.entries, [fixture.firstPanelID, fixture.secondPanelID])
        XCTAssertTrue(store.navigateBack())
        XCTAssertEqual(try focusedPanel(in: store), fixture.firstPanelID)
    }

    private func makeStore(state: AppState) -> AppStore {
        AppStore(state: state, persistTerminalFontPreference: false, windowActivationHandler: { _ in })
    }

    private func focusedPanel(in store: AppStore) throws -> UUID {
        let windowID = try XCTUnwrap(store.state.selectedWindowID)
        let workspace = try XCTUnwrap(store.state.workspaceSelection(in: windowID)?.workspace)
        if workspace.rightAuxPanel.isVisible, let panelID = workspace.rightAuxPanel.focusedPanelID {
            return panelID
        }
        return try XCTUnwrap(workspace.selectedTab?.resolvedFocusedPanelID)
    }

    private func twoWindowFixture() throws -> (
        state: AppState, firstWindowID: UUID, secondWindowID: UUID, firstPanelID: UUID, secondPanelID: UUID
    ) {
        let first = WorkspaceState.bootstrap(title: "First")
        let second = WorkspaceState.bootstrap(title: "Second")
        let firstWindowID = UUID(), secondWindowID = UUID()
        let frame = CGRectCodable(x: 0, y: 0, width: 800, height: 600)
        let state = AppState(
            windows: [
                WindowState(id: firstWindowID, frame: frame, workspaceIDs: [first.id], selectedWorkspaceID: first.id),
                WindowState(id: secondWindowID, frame: frame, workspaceIDs: [second.id], selectedWorkspaceID: second.id),
            ],
            workspacesByID: [first.id: first, second.id: second],
            selectedWindowID: firstWindowID
        )
        return (state, firstWindowID, secondWindowID, try XCTUnwrap(first.focusedPanelID), try XCTUnwrap(second.focusedPanelID))
    }
}
