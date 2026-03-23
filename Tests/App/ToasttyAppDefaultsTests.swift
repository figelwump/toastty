@testable import ToasttyApp
import XCTest

final class ToasttyAppDefaultsTests: XCTestCase {
    func testRuntimeHomeUsesIsolatedDefaultsSuite() {
        let key = "toastty-app-defaults-tests-\(UUID().uuidString)"
        let runtimeOne = "/tmp/toastty-runtime-home-tests/defaults-runtime-a"
        let runtimeTwo = "/tmp/toastty-runtime-home-tests/defaults-runtime-b"

        let defaultsOne = ToasttyAppDefaults.make(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: ["TOASTTY_RUNTIME_HOME": runtimeOne]
        )
        let defaultsTwo = ToasttyAppDefaults.make(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: ["TOASTTY_RUNTIME_HOME": runtimeTwo]
        )

        defaultsOne.removeObject(forKey: key)
        defaultsTwo.removeObject(forKey: key)

        defaultsOne.set("one", forKey: key)

        XCTAssertEqual(defaultsOne.string(forKey: key), "one")
        XCTAssertNil(defaultsTwo.object(forKey: key))

        defaultsOne.removeObject(forKey: key)
        defaultsTwo.removeObject(forKey: key)
    }

    func testWorktreeRootUsesStableIsolatedDefaultsSuite() {
        let key = "toastty-app-defaults-worktree-tests-\(UUID().uuidString)"
        let worktreeRoot = "/tmp/toastty-runtime-home-tests/worktrees/main"

        let defaultsOne = ToasttyAppDefaults.make(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: ["TOASTTY_DEV_WORKTREE_ROOT": worktreeRoot]
        )
        let defaultsTwo = ToasttyAppDefaults.make(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: ["TOASTTY_DEV_WORKTREE_ROOT": worktreeRoot]
        )

        defaultsOne.removeObject(forKey: key)
        defaultsTwo.removeObject(forKey: key)

        defaultsOne.set("shared", forKey: key)

        XCTAssertEqual(defaultsTwo.string(forKey: key), "shared")

        defaultsOne.removeObject(forKey: key)
        defaultsTwo.removeObject(forKey: key)
    }
}
