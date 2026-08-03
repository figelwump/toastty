import Foundation
import XCTest
@testable import ToasttyApp

final class CodexSkillsManagementSheetTests: XCTestCase {
    func testManagementRowsExposeTheExactFourQualifiedSkillsAndSummaries() {
        XCTAssertEqual(
            ToasttyAgentPluginBundle.skills.map { "toastty:\($0.name)" },
            [
                "toastty:toastty-capabilities",
                "toastty:toastty-open-markdown",
                "toastty:toastty-scratchpad",
                "toastty:worktree-create",
            ]
        )
        XCTAssertTrue(ToasttyAgentPluginBundle.skills.allSatisfy { $0.summary.isEmpty == false })
    }

    func testProvisionedNoticeIsClaimedOnceByItsTargetWindow() throws {
        let suiteName = "toastty-codex-skills-notice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let targetWindowID = UUID()

        XCTAssertFalse(
            CodexSkillsProvisionedNoticeStore.claim(
                for: UUID(),
                notificationObject: targetWindowID,
                userDefaults: defaults
            )
        )
        XCTAssertTrue(
            CodexSkillsProvisionedNoticeStore.claim(
                for: targetWindowID,
                notificationObject: targetWindowID,
                userDefaults: defaults
            )
        )
        XCTAssertFalse(
            CodexSkillsProvisionedNoticeStore.claim(
                for: targetWindowID,
                notificationObject: targetWindowID,
                userDefaults: defaults
            )
        )
    }
}
