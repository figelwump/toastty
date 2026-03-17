@testable import ToasttyApp
import XCTest

final class WorkspaceLayoutPersistenceLocationTests: XCTestCase {
    func testFileURLUsesRuntimeHomeWhenSet() {
        let fileURL = WorkspaceLayoutPersistenceLocation.fileURL(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: ["TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-home-tests/workspace-runtime"]
        )

        XCTAssertEqual(
            fileURL.path,
            "/tmp/toastty-runtime-home-tests/workspace-runtime/workspace-layout-profiles.json"
        )
    }
}
