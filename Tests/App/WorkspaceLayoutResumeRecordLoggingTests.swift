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
}
