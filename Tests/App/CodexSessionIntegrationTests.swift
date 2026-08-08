import XCTest
@testable import ToasttyApp

final class CodexSkillsIntegrationTests: XCTestCase {
    func testProfileContractConstants() {
        XCTAssertEqual(CodexSkillsContract.profileName, "toastty-managed")
        XCTAssertEqual(CodexSkillsContract.profileConfigFileName, "toastty-managed.config.toml")
        XCTAssertEqual(CodexSkillsContract.pluginSelector, "toastty@toastty")
    }

    func testManagedProfileConfigCarriesOwnershipMarkerAndPluginEnablement() {
        let contents = CodexManagedProfileConfig.fileContents

        XCTAssertTrue(contents.hasPrefix(CodexManagedProfileConfig.ownershipMarker + "\n"))
        XCTAssertTrue(contents.contains(#"[plugins."toastty@toastty"]"#))
        XCTAssertTrue(contents.contains("enabled = true"))
        XCTAssertTrue(CodexManagedProfileConfig.isToasttyOwned(contents))
    }

    func testForeignProfileContentsAreNotConsideredToasttyOwned() {
        XCTAssertFalse(
            CodexManagedProfileConfig.isToasttyOwned(
                #"[plugins."toastty@toastty"]"# + "\nenabled = true\n"
            )
        )
        XCTAssertFalse(CodexManagedProfileConfig.isToasttyOwned(""))
    }

    func testExactMarkerCanMoveButNearMatchesRemainForeign() {
        XCTAssertTrue(
            CodexManagedProfileConfig.isToasttyOwned(
                CodexManagedProfileConfig.fileContents(includeUserPlugin: true)
            )
        )
        // A leading UTF-8 BOM and surrounding whitespace are tolerated.
        XCTAssertTrue(
            CodexManagedProfileConfig.isToasttyOwned(
                "\u{FEFF}" + CodexManagedProfileConfig.fileContents
            )
        )
        XCTAssertTrue(
            CodexManagedProfileConfig.isToasttyOwned(
                "  " + CodexManagedProfileConfig.ownershipMarker + "\nmodel = \"gpt-5\"\n"
            )
        )
        let displaced = "model = \"gpt-5\"\n\(CodexManagedProfileConfig.ownershipMarker)\n"
        XCTAssertTrue(CodexManagedProfileConfig.isToasttyOwned(displaced))
        let windowsLineEndings = "model = \"gpt-5\"\r\n\(CodexManagedProfileConfig.ownershipMarker)\r\n"
        XCTAssertTrue(CodexManagedProfileConfig.isToasttyOwned(windowsLineEndings))
        XCTAssertFalse(
            CodexManagedProfileConfig.isToasttyOwned(
                CodexManagedProfileConfig.ownershipMarker + " extra\n"
            )
        )
        XCTAssertFalse(
            CodexManagedProfileConfig.isToasttyOwned(
                "quoted: " + CodexManagedProfileConfig.ownershipMarker + "\n"
            )
        )
    }

    func testMergingPreservesNonToasttySettingsAndReplacesManagedTables() {
        let original = """
        model = "gpt-5.6-luna"
        model_reasoning_effort = "medium"
        \(CodexManagedProfileConfig.ownershipMarker)
        [plugins."toastty@toastty"]
        enabled = false

        [plugins."example@example"]
        enabled = true

        """

        let merged = CodexManagedProfileConfig.mergedFileContents(
            preserving: original,
            includeUserPlugin: true
        )

        XCTAssertTrue(merged.contains("model = \"gpt-5.6-luna\""))
        XCTAssertTrue(merged.contains("model_reasoning_effort = \"medium\""))
        XCTAssertTrue(merged.contains(#"[plugins."example@example"]"#))
        XCTAssertEqual(merged.components(separatedBy: CodexManagedProfileConfig.ownershipMarker).count, 2)
        XCTAssertTrue(merged.contains(#"[plugins."toastty-user@toastty-user"]"#))
    }

    func testRemovingManagedContentsLeavesOtherProfileContent() {
        let original = """
        model = "gpt-5"
        \(CodexManagedProfileConfig.ownershipMarker)
        [plugins."toastty@toastty"]
        enabled = true

        [[mcp_servers.example.tools]]
        name = "search"

        """

        let preserved = CodexManagedProfileConfig.removingManagedContents(from: original)

        XCTAssertEqual(
            preserved,
            "model = \"gpt-5\"\n[[mcp_servers.example.tools]]\nname = \"search\"\n"
        )
    }
}
