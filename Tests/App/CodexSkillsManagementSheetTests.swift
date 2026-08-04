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

    func testProvisionedNoticeIsClaimedOncePerAgentByItsTargetWindow() throws {
        let suiteName = "toastty-codex-skills-notice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let targetWindowID = UUID()

        let codexNotice = ManagedAgentSkillsProvisionedNotice(
            windowID: targetWindowID,
            agent: .codex
        )
        let claudeNotice = ManagedAgentSkillsProvisionedNotice(
            windowID: targetWindowID,
            agent: .claude
        )

        XCTAssertNil(
            ManagedAgentSkillsProvisionedNoticeStore.claim(
                for: UUID(),
                notificationObject: codexNotice,
                userDefaults: defaults
            )
        )
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedNoticeStore.claim(
                for: targetWindowID,
                notificationObject: codexNotice,
                userDefaults: defaults
            ),
            .codex
        )
        XCTAssertNil(
            ManagedAgentSkillsProvisionedNoticeStore.claim(
                for: targetWindowID,
                notificationObject: codexNotice,
                userDefaults: defaults
            )
        )
        XCTAssertEqual(
            ManagedAgentSkillsProvisionedNoticeStore.claim(
                for: targetWindowID,
                notificationObject: claudeNotice,
                userDefaults: defaults
            ),
            .claude
        )
    }
}
