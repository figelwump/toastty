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

    /// Ownership requires the marker as the first line; a marker pasted into
    /// the middle of a user-authored overlay does not surrender the file.
    func testOwnershipMarkerMustBeTheFirstLine() {
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
        XCTAssertFalse(
            CodexManagedProfileConfig.isToasttyOwned(
                "# user-authored overlay\n\(CodexManagedProfileConfig.ownershipMarker)\nmodel = \"gpt-5\"\n"
            )
        )
    }
}
