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
}
