#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import XCTest

final class TerminalProcessWorkingDirectoryResolverTests: XCTestCase {
    func testObservedLaunchContextSnapshotParsesToasttyEnvironmentValues() throws {
        let panelID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let commandOutput = """
        -zsh TOASTTY_PANEL_ID=\(panelID.uuidString) TOASTTY_LAUNCH_REASON=restore TOASTTY_PANE_JOURNAL_FILE=/tmp/toastty/history/pane-journals/\(panelID.uuidString).journal PATH=/usr/bin:/bin
        """

        let snapshot = try XCTUnwrap(
            TerminalProcessWorkingDirectoryResolver.observedLaunchContextSnapshot(
                fromProcessCommandOutput: commandOutput
            )
        )

        XCTAssertEqual(snapshot.panelID, panelID.uuidString)
        XCTAssertEqual(snapshot.launchReason, "restore")
        XCTAssertEqual(
            snapshot.paneJournalFile,
            "/tmp/toastty/history/pane-journals/\(panelID.uuidString).journal"
        )
        XCTAssertEqual(snapshot.paneJournalPanelID, panelID.uuidString)
        XCTAssertTrue(snapshot.containsLaunchContext)
        XCTAssertTrue(snapshot.commandSample.contains(panelID.uuidString))
    }

    func testObservedLaunchContextSnapshotReturnsSnapshotWithoutToasttyEnvironment() throws {
        let commandOutput = "-zsh -l"

        let snapshot = try XCTUnwrap(
            TerminalProcessWorkingDirectoryResolver.observedLaunchContextSnapshot(
                fromProcessCommandOutput: commandOutput
            )
        )

        XCTAssertNil(snapshot.panelID)
        XCTAssertNil(snapshot.launchReason)
        XCTAssertNil(snapshot.paneJournalFile)
        XCTAssertNil(snapshot.paneJournalPanelID)
        XCTAssertFalse(snapshot.containsLaunchContext)
        XCTAssertEqual(snapshot.commandSample, commandOutput)
    }
}
#endif
