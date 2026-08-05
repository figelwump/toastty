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
}
