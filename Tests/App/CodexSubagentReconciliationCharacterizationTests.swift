import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

@MainActor
final class CodexSubagentReconciliationCharacterizationTests: XCTestCase {
    func testInferredFollowUpStartRemainsBlockedThroughFallbackPlannerProjection() async throws {
        let launchStart = Date()
        let sessionID = "codex-fallback-reconciliation"
        let activityID = "/root/plan_review"
        let controlActivityID = "/root/control"
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-codex-reconciliation-\(UUID().uuidString).jsonl")
        try Data().write(to: rolloutURL)

        let state = AppState.bootstrap()
        let window = try XCTUnwrap(state.windows.first)
        let workspaceID = try XCTUnwrap(window.selectedWorkspaceID ?? window.workspaceIDs.first)
        let panelID = try XCTUnwrap(state.workspacesByID[workspaceID]?.focusedPanelID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let planner = ManagedAgentLaunchPlanner(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            nowProvider: { launchStart },
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .sessionLogFallback(reason: "characterization") },
            readVisibleText: { _ in nil },
            promptState: { _ in .unavailable },
            nativeSessionObserverRegistry: CodexReconciliationNativeSessionObserverStub()
        )
        defer {
            sessionRuntimeStore.stopSession(sessionID: sessionID, at: launchStart)
            try? FileManager.default.removeItem(at: rolloutURL)
        }

        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: panelID,
            windowID: window.id,
            workspaceID: workspaceID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "characterization"),
            cwd: "/tmp/repo",
            repoRoot: "/tmp/repo",
            at: launchStart
        )
        XCTAssertTrue(store.send(
            .updateTerminalPanelResumeRecord(
                panelID: panelID,
                resumeRecord: ManagedAgentResumeRecord(
                    agent: .codex,
                    nativeSessionID: "native-reconciliation",
                    sessionFilePath: rolloutURL.path,
                    cwd: "/tmp/repo",
                    capturedAt: launchStart
                )
            )
        ))
        XCTAssertEqual(planner.codexRolloutWatcherPathsForTesting[sessionID], rolloutURL.path)

        let initialStart = launchStart.addingTimeInterval(1)
        try appendCodexReconciliationLogLine(
            #"{"timestamp":"\#(codexReconciliationTimestamp(initialStart))","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_initial","occurred_at_ms":\#(Int(initialStart.timeIntervalSince1970 * 1_000)),"agent_path":"/root/plan_review","kind":"started"}}"#,
            to: rolloutURL
        )
        await waitForCodexReconciliation {
            sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?
                .backgroundActivitiesByID[activityID] != nil
        }
        XCTAssertNotNil(sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID[activityID])

        let finalAnswer = launchStart.addingTimeInterval(2)
        try appendCodexReconciliationLogLine(
            #"{"timestamp":"\#(codexReconciliationTimestamp(finalAnswer))","type":"response_item","payload":{"type":"agent_message","author":"/root/plan_review","recipient":"/root","content":[{"type":"input_text","text":"Message Type: FINAL_ANSWER\nTask name: /root"}]}}"#,
            to: rolloutURL
        )
        await waitForCodexReconciliation {
            sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?
                .backgroundActivitiesByID[activityID] == nil
        }
        XCTAssertNil(sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID[activityID])

        let followUp = launchStart.addingTimeInterval(3)
        let controlStart = launchStart.addingTimeInterval(4)
        try appendCodexReconciliationLogLine(
            #"""
            {"timestamp":"\#(codexReconciliationTimestamp(followUp))","type":"response_item","payload":{"type":"agent_message","author":"/root","recipient":"/root/plan_review","content":[{"type":"input_text","text":"Message Type: NEW_TASK\nTask name: /root/plan_review"}]}}
            {"timestamp":"\#(codexReconciliationTimestamp(controlStart))","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_control","occurred_at_ms":\#(Int(controlStart.timeIntervalSince1970 * 1_000)),"agent_path":"/root/control","kind":"started"}}
            """#,
            to: rolloutURL
        )
        await waitForCodexReconciliation {
            sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?
                .backgroundActivitiesByID[controlActivityID] != nil
        }

        let activeSession = try XCTUnwrap(
            sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)
        )
        XCTAssertNil(activeSession.backgroundActivitiesByID[activityID])
        XCTAssertNotNil(activeSession.backgroundActivitiesByID[controlActivityID])
        XCTAssertEqual(
            sessionRuntimeStore.workspaceStatuses(for: workspaceID).first?.children.map(\.id),
            [controlActivityID]
        )

        sessionRuntimeStore.stopSession(sessionID: sessionID, at: launchStart)
        await waitForCodexReconciliation {
            planner.codexRolloutWatcherPathsForTesting[sessionID] == nil
        }
    }
}

@MainActor
private final class CodexReconciliationNativeSessionObserverStub: ManagedAgentNativeSessionObserving {
    func startObservation(_: ManagedAgentNativeSessionObservationContext) {}
    func cancelObservation(sessionID _: String) {}
}

private func codexReconciliationTimestamp(_ date: Date) -> String {
    date.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

private func appendCodexReconciliationLogLine(_ line: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line.hasSuffix("\n") ? line : line + "\n").utf8))
}

@MainActor
private func waitForCodexReconciliation(
    timeout: TimeInterval = 2,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while condition() == false && Date() < deadline {
        await Task.yield()
    }
}
