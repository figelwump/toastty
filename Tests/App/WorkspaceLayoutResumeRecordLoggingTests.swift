import CoreState
import XCTest
@testable import ToasttyApp

@MainActor
final class WorkspaceLayoutResumeRecordLoggingTests: XCTestCase {
    func testSnapshotCountsAndSummarizesManagedAgentResumeRecords() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/toastty/session.jsonl",
            cwd: "/tmp/toastty",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(store.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: record)))

        let snapshot = WorkspaceLayoutSnapshot(state: store.state)
        XCTAssertEqual(snapshot.managedAgentResumeRecordCount, 1)
        XCTAssertEqual(snapshot.managedAgentResumeRecordSummary(), "\(panelID.uuidString):codex")
    }

    func testSnapshotResumeRecordLogEntriesIncludeWorkspaceTabAndPanelContext() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try XCTUnwrap(store.state.selectedWorkspaceSelection())
        let workspaceID = selection.workspaceID
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let record = ManagedAgentResumeRecord(
            agent: .claude,
            nativeSessionID: "db4f311b-12d0-4f61-ba81-0ae44ed10492",
            sessionFilePath: "/tmp/claude/session.jsonl",
            cwd: "/tmp/active-session-repo",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(store.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: record)))

        let snapshot = WorkspaceLayoutSnapshot(state: store.state)
        let entry = try XCTUnwrap(snapshot.managedAgentResumeRecordLogEntries.first)
        let metadata = entry.metadata
        XCTAssertEqual(metadata["workspace_id"], workspaceID.uuidString)
        XCTAssertEqual(metadata["tab_id"], selection.workspace.resolvedSelectedTabID?.uuidString)
        XCTAssertEqual(metadata["panel_id"], panelID.uuidString)
        XCTAssertEqual(metadata["panel_kind"], "terminal")
        XCTAssertEqual(metadata["agent"], "claude")
        XCTAssertEqual(metadata["native_session_id"], "db4f311b-12d0-4f61-ba81-0ae44ed10492")
        XCTAssertEqual(metadata["session_file_basename"], "session.jsonl")
        XCTAssertEqual(metadata["tab_selected"], "true")
        XCTAssertEqual(metadata["workspace_selected"], "true")
    }

    func testPersistenceCoordinatorLogsTopologyAndResumeRecordLifecycle() throws {
        let fileURL = temporaryLayoutFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let reducer = AppReducer()
        let initialState = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(initialState.selectedWorkspaceSelection()?.workspaceID)
        var splitState = initialState
        XCTAssertTrue(
            reducer.send(
                .splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right),
                state: &splitState
            )
        )

        var logs: [(message: String, metadata: [String: String])] = []
        let coordinator = WorkspaceLayoutPersistenceCoordinator(
            context: WorkspaceLayoutPersistenceContext(
                profileID: "test-profile",
                fileURL: fileURL,
                shouldMigrateLegacyStore: false
            ),
            layoutLifecycleLogger: { message, metadata in
                logs.append((message, metadata))
            }
        )

        coordinator.handleAppliedAction(
            .splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right),
            previousState: initialState,
            nextState: splitState
        )

        let panelCreatedLog = try XCTUnwrap(logs.first { log in
            log.message == "Workspace layout topology changed" &&
                log.metadata["mutation"] == "panel_created"
        })
        XCTAssertEqual(panelCreatedLog.metadata["action"], "splitFocusedSlotInDirection")
        XCTAssertEqual(panelCreatedLog.metadata["workspace_id"], workspaceID.uuidString)
        XCTAssertNotNil(panelCreatedLog.metadata["source_panel_id"])

        logs.removeAll()
        let focusedPanelID = try XCTUnwrap(splitState.selectedWorkspaceSelection()?.workspace.focusedPanelID)
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/toastty/session.jsonl",
            cwd: "/tmp/toastty",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var resumeState = splitState
        XCTAssertTrue(
            reducer.send(
                .updateTerminalPanelResumeRecord(panelID: focusedPanelID, resumeRecord: record),
                state: &resumeState
            )
        )

        coordinator.handleAppliedAction(
            .updateTerminalPanelResumeRecord(panelID: focusedPanelID, resumeRecord: record),
            previousState: splitState,
            nextState: resumeState
        )

        let resumeLog = try XCTUnwrap(logs.first { log in
            log.message == "Managed agent resume record changed"
        })
        XCTAssertEqual(resumeLog.metadata["mutation"], "managed_agent_resume_record_changed")
        XCTAssertEqual(resumeLog.metadata["resume_record_action"], "attach")
        XCTAssertEqual(resumeLog.metadata["panel_id"], focusedPanelID.uuidString)
        XCTAssertEqual(resumeLog.metadata["agent"], "codex")
        XCTAssertEqual(resumeLog.metadata["native_session_id"], "019e2823-f520-7690-91b6-cd84eb52dd8a")
        XCTAssertEqual(resumeLog.metadata["session_file_basename"], "session.jsonl")
        XCTAssertEqual(resumeLog.metadata["next_count"], "1")

        logs.removeAll()
        var clearedState = resumeState
        XCTAssertTrue(
            reducer.send(
                .updateTerminalPanelResumeRecord(panelID: focusedPanelID, resumeRecord: nil),
                state: &clearedState
            )
        )

        coordinator.handleAppliedAction(
            .updateTerminalPanelResumeRecord(panelID: focusedPanelID, resumeRecord: nil),
            previousState: resumeState,
            nextState: clearedState
        )

        let clearLog = try XCTUnwrap(logs.first { log in
            log.message == "Managed agent resume record changed"
        })
        XCTAssertEqual(clearLog.metadata["resume_record_action"], "clear")
        XCTAssertEqual(clearLog.metadata["panel_id"], focusedPanelID.uuidString)
        XCTAssertEqual(clearLog.metadata["previous_agent"], "codex")
        XCTAssertEqual(clearLog.metadata["resume_record_present"], "false")
        XCTAssertEqual(clearLog.metadata["next_count"], "0")

        logs.removeAll()
        var removedState = resumeState
        XCTAssertTrue(
            reducer.send(
                .closePanel(panelID: focusedPanelID),
                state: &removedState
            )
        )

        coordinator.handleAppliedAction(
            .closePanel(panelID: focusedPanelID),
            previousState: resumeState,
            nextState: removedState
        )

        let removeLog = try XCTUnwrap(logs.first { log in
            log.message == "Managed agent resume record changed"
        })
        XCTAssertEqual(removeLog.metadata["resume_record_action"], "remove_with_panel")
        XCTAssertEqual(removeLog.metadata["panel_id"], focusedPanelID.uuidString)
        XCTAssertEqual(removeLog.metadata["previous_agent"], "codex")
        XCTAssertEqual(removeLog.metadata["next_count"], "0")
    }

    func testPersistenceCoordinatorToleratesDuplicatePanelIDsInDiagnosticProjection() throws {
        let fileURL = temporaryLayoutFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        var previousState = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(previousState.selectedWorkspaceSelection()?.workspaceID)
        let tabID = try XCTUnwrap(previousState.workspacesByID[workspaceID]?.resolvedSelectedTabID)
        let panelID = try XCTUnwrap(previousState.workspacesByID[workspaceID]?.focusedPanelID)

        var previousWorkspace = try XCTUnwrap(previousState.workspacesByID[workspaceID])
        var previousTab = try XCTUnwrap(previousWorkspace.tabsByID[tabID])
        previousTab.layoutTree = .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: UUID(), panelID: panelID),
            second: .slot(slotID: UUID(), panelID: panelID)
        )
        previousWorkspace.tabsByID[tabID] = previousTab
        previousState.workspacesByID[workspaceID] = previousWorkspace

        let record = ManagedAgentResumeRecord(
            agent: .claude,
            nativeSessionID: "db4f311b-12d0-4f61-ba81-0ae44ed10492",
            sessionFilePath: "/tmp/claude/session.jsonl",
            cwd: "/tmp/active-session-repo",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var nextState = previousState
        var nextWorkspace = try XCTUnwrap(nextState.workspacesByID[workspaceID])
        var nextTab = try XCTUnwrap(nextWorkspace.tabsByID[tabID])
        guard case .terminal(var terminalState) = nextTab.panels[panelID] else {
            XCTFail("Expected bootstrap panel to be terminal")
            return
        }
        terminalState.resumeRecord = record
        nextTab.panels[panelID] = .terminal(terminalState)
        nextWorkspace.tabsByID[tabID] = nextTab
        nextState.workspacesByID[workspaceID] = nextWorkspace

        var logs: [(message: String, metadata: [String: String])] = []
        let coordinator = WorkspaceLayoutPersistenceCoordinator(
            context: WorkspaceLayoutPersistenceContext(
                profileID: "test-profile",
                fileURL: fileURL,
                shouldMigrateLegacyStore: false
            ),
            layoutLifecycleLogger: { message, metadata in
                logs.append((message, metadata))
            }
        )

        coordinator.handleAppliedAction(
            .updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: record),
            previousState: previousState,
            nextState: nextState
        )

        let resumeLog = try XCTUnwrap(logs.first { log in
            log.message == "Managed agent resume record changed"
        })
        XCTAssertEqual(resumeLog.metadata["resume_record_action"], "attach")
        XCTAssertEqual(resumeLog.metadata["panel_id"], panelID.uuidString)
    }

    func testApplicationWillTerminateFlushPreservesScopedResumeRecord() throws {
        let fileURL = temporaryLayoutFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try XCTUnwrap(store.state.selectedWorkspaceSelection())
        let panelID = try XCTUnwrap(selection.workspace.focusedPanelID)
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/toastty/session.jsonl",
            cwd: "/tmp/toastty",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scopedWorkspaceIDs: [selection.workspaceID]
        )
        XCTAssertTrue(store.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: record)))

        let coordinator = WorkspaceLayoutPersistenceCoordinator(
            context: WorkspaceLayoutPersistenceContext(
                profileID: "test-profile",
                fileURL: fileURL,
                shouldMigrateLegacyStore: false
            )
        )

        coordinator.flushCurrentState(store.state, reason: "application_will_terminate")

        let persistedLayout = try XCTUnwrap(
            WorkspaceLayoutPersistenceStore(fileURL: fileURL).loadLayout(for: "test-profile")?.layout
        )
        let restoredState = persistedLayout.makeAppState()
        let restoredWorkspace = try XCTUnwrap(restoredState.workspacesByID[selection.workspaceID])
        guard case .terminal(let restoredTerminalState)? = restoredWorkspace.panelState(for: panelID) else {
            XCTFail("Expected persisted panel to restore as terminal")
            return
        }

        XCTAssertEqual(restoredTerminalState.resumeRecord?.scopedWorkspaceIDs, Set([selection.workspaceID]))
    }

    private func temporaryLayoutFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "toastty-layout-resume-record-logging-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "workspace-layout-profiles.json", directoryHint: .notDirectory)
    }
}
