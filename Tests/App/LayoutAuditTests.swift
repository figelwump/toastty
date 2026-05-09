@testable import ToasttyApp
import CoreState
import Foundation
import XCTest

final class LayoutAuditTests: XCTestCase {
    func testDiffReportsRemovedWorkspaceAndPanels() {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let windowID = UUID()
        let before = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1000, height: 700),
                    workspaceIDs: [firstWorkspace.id, secondWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: windowID
        )
        let after = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1000, height: 700),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
            ],
            workspacesByID: [firstWorkspace.id: firstWorkspace],
            selectedWindowID: windowID
        )

        let diff = LayoutAuditDiff(
            before: LayoutAuditSummary(state: before),
            after: LayoutAuditSummary(state: after)
        )

        XCTAssertEqual(diff.removedWorkspaceIDs, [secondWorkspace.id])
        XCTAssertEqual(diff.removedPanelIDs, Set(secondWorkspace.allPanelsByID.keys))
        XCTAssertTrue(diff.didDropContainerLayout)
        XCTAssertEqual(diff.metadata["workspace_count_before"], "2")
        XCTAssertEqual(diff.metadata["workspace_count_after"], "1")
        XCTAssertEqual(diff.metadata["removed_workspace_ids"], secondWorkspace.id.uuidString)
    }

    func testSummaryCountsRightAuxPanelIDsInLiveStateAndLayoutSnapshots() {
        let workspaceID = UUID()
        let mainPanelID = UUID()
        let rightAuxPanelID = UUID()
        let rightAuxTabID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Aux",
            layoutTree: .slot(slotID: UUID(), panelID: mainPanelID),
            panels: [
                mainPanelID: .terminal(TerminalPanelState(title: "Main", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: mainPanelID,
            rightAuxPanel: RightAuxPanelState(
                isVisible: true,
                activeTabID: rightAuxTabID,
                tabIDs: [rightAuxTabID],
                tabsByID: [
                    rightAuxTabID: RightAuxPanelTabState(
                        id: rightAuxTabID,
                        identity: .browserSession(rightAuxPanelID),
                        panelID: rightAuxPanelID,
                        panelState: .web(WebPanelState(definition: .browser, initialURL: "https://example.com"))
                    ),
                ]
            )
        )
        let state = AppState(
            windows: [
                WindowState(
                    id: UUID(),
                    frame: CGRectCodable(x: 0, y: 0, width: 1000, height: 700),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: nil
        )

        XCTAssertEqual(LayoutAuditSummary(state: state).panelIDs, [mainPanelID, rightAuxPanelID])
        XCTAssertEqual(
            LayoutAuditSummary(layout: WorkspaceLayoutSnapshot(state: state)).panelIDs,
            [mainPanelID, rightAuxPanelID]
        )
    }

    func testDestructiveActionTargetMetadata() {
        let workspaceID = UUID()
        let tabID = UUID()

        let action = AppAction.closeWorkspaceTab(workspaceID: workspaceID, tabID: tabID)

        XCTAssertTrue(action.isDestructiveLayoutAction)
        XCTAssertEqual(action.layoutAuditTargetMetadata["target_workspace_id"], workspaceID.uuidString)
        XCTAssertEqual(action.layoutAuditTargetMetadata["target_tab_id"], tabID.uuidString)
        XCTAssertFalse(AppAction.selectWindow(windowID: UUID()).isDestructiveLayoutAction)
    }

    func testPendingWorkspaceCloseRequestEqualityIgnoresSourceButPreservesIt() {
        let windowID = UUID()
        let workspaceID = UUID()
        let commandRequest = PendingWorkspaceCloseRequest(
            windowID: windowID,
            workspaceID: workspaceID,
            source: .command("close_workspace")
        )
        let uiRequest = PendingWorkspaceCloseRequest(
            windowID: windowID,
            workspaceID: workspaceID,
            source: .ui("sidebar_workspace_close")
        )

        XCTAssertEqual(commandRequest, uiRequest)
        XCTAssertEqual(commandRequest.source.metadata["source"], "command")
        XCTAssertEqual(commandRequest.source.metadata["source_detail"], "close_workspace")
    }

    @MainActor
    func testPersistenceFlushLogsDropTriggerFromActionThatRemovedLayout() throws {
        let fileURL = temporaryLayoutFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        var auditLogs: [[String: String]] = []
        let coordinator = WorkspaceLayoutPersistenceCoordinator(
            context: WorkspaceLayoutPersistenceContext(
                profileID: "test-profile",
                fileURL: fileURL,
                shouldMigrateLegacyStore: false
            ),
            persistDropAuditLogger: { metadata in
                auditLogs.append(metadata)
            }
        )
        let states = makeMovedThenClosedWorkspaceStates()

        coordinator.handleAppliedAction(
            .moveWorkspace(windowID: states.windowID, fromIndex: 0, toIndex: 1),
            previousState: states.initial,
            nextState: states.moved
        )
        coordinator.handleAppliedAction(
            .closeWorkspace(workspaceID: states.closedWorkspaceID),
            previousState: states.moved,
            nextState: states.closed
        )

        coordinator.flushCurrentState(states.closed, reason: "test_flush")

        let metadata = try XCTUnwrap(auditLogs.first)
        XCTAssertEqual(metadata["trigger"], "action_closeWorkspace")
        XCTAssertEqual(metadata["reason"], "test_flush")
        XCTAssertEqual(metadata["removed_workspace_ids"], states.closedWorkspaceID.uuidString)
        XCTAssertEqual(
            WorkspaceLayoutPersistenceStore(fileURL: fileURL)
                .loadLayout(for: "test-profile")?
                .layout,
            WorkspaceLayoutSnapshot(state: states.closed)
        )
    }

    @MainActor
    func testPersistenceDebounceLogsDropTriggerFromActionThatRemovedLayout() async throws {
        let fileURL = temporaryLayoutFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        var auditLogs: [[String: String]] = []
        let coordinator = WorkspaceLayoutPersistenceCoordinator(
            context: WorkspaceLayoutPersistenceContext(
                profileID: "test-profile",
                fileURL: fileURL,
                shouldMigrateLegacyStore: false
            ),
            persistDropAuditLogger: { metadata in
                auditLogs.append(metadata)
            }
        )
        let states = makeMovedThenClosedWorkspaceStates()

        coordinator.handleAppliedAction(
            .moveWorkspace(windowID: states.windowID, fromIndex: 0, toIndex: 1),
            previousState: states.initial,
            nextState: states.moved
        )
        coordinator.handleAppliedAction(
            .closeWorkspace(workspaceID: states.closedWorkspaceID),
            previousState: states.moved,
            nextState: states.closed
        )

        try await Task.sleep(nanoseconds: 600_000_000)

        let metadata = try XCTUnwrap(auditLogs.first)
        XCTAssertEqual(metadata["trigger"], "action_closeWorkspace")
        XCTAssertEqual(metadata["reason"], "action_closeWorkspace")
        XCTAssertEqual(metadata["removed_workspace_ids"], states.closedWorkspaceID.uuidString)
        XCTAssertEqual(
            WorkspaceLayoutPersistenceStore(fileURL: fileURL)
                .loadLayout(for: "test-profile")?
                .layout,
            WorkspaceLayoutSnapshot(state: states.closed)
        )
    }

    private func temporaryLayoutFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "toastty-layout-audit-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "workspace-layout-profiles.json", directoryHint: .notDirectory)
    }

    private func makeMovedThenClosedWorkspaceStates() -> (
        windowID: UUID,
        closedWorkspaceID: UUID,
        initial: AppState,
        moved: AppState,
        closed: AppState
    ) {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let windowID = UUID()
        let frame = CGRectCodable(x: 0, y: 0, width: 1000, height: 700)
        let initial = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: frame,
                    workspaceIDs: [firstWorkspace.id, secondWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: windowID
        )
        let moved = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: frame,
                    workspaceIDs: [secondWorkspace.id, firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: windowID
        )
        let closed = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: frame,
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
            ],
            selectedWindowID: windowID
        )

        return (
            windowID: windowID,
            closedWorkspaceID: secondWorkspace.id,
            initial: initial,
            moved: moved,
            closed: closed
        )
    }
}
