import XCTest
@testable import ToasttyApp

final class CodexSkillsIntegrationTests: XCTestCase {
    func testSkillsOverrideIsDeterministicDeduplicatedAndEscaped() {
        let override = CodexSkillsConfigSerializer.skillsConfigOverride(
            enabling: [
                "toastty:worktree-create",
                "toastty:toastty-\"scratchpad\\",
                "toastty:worktree-create",
            ]
        )

        XCTAssertEqual(
            override,
            #"skills.config=[{name="toastty:toastty-\"scratchpad\\",enabled=true},{name="toastty:worktree-create",enabled=true}]"#
        )
        XCTAssertFalse(override.contains("hooks"))
    }

    func testRetiredSkillRemainsADisabledNameTombstone() {
        XCTAssertEqual(CodexSkillsContract.retiredQualifiedSkillNames, ["toastty:worktree-done"])
    }
}
