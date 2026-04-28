@testable import ToasttyApp
import XCTest

final class ToasttyAppDefaultsTests: XCTestCase {
    func testAppKitDefaultPreferencesRegistersFasterToolTipDelay() throws {
        let suiteName = "toastty-appkit-defaults-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        AppKitDefaultPreferences.registerToolTipTiming(in: defaults)

        XCTAssertEqual(
            defaults.integer(forKey: AppKitDefaultPreferences.initialToolTipDelayKey),
            AppKitDefaultPreferences.initialToolTipDelayMilliseconds
        )
        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?[AppKitDefaultPreferences.initialToolTipDelayKey]
        )
    }

    func testAppKitDefaultPreferencesDoesNotOverrideExplicitToolTipDelay() throws {
        let suiteName = "toastty-appkit-defaults-override-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(900, forKey: AppKitDefaultPreferences.initialToolTipDelayKey)

        AppKitDefaultPreferences.registerToolTipTiming(in: defaults)

        XCTAssertEqual(defaults.integer(forKey: AppKitDefaultPreferences.initialToolTipDelayKey), 900)
    }

    func testAppKitDefaultPreferencesRegistersToolTipDelayForStandardDefaultsWhenUsingIsolatedSuite() throws {
        let isolatedSuiteName = "toastty-appkit-defaults-isolated-tests-\(UUID().uuidString)"
        let standardSuiteName = "toastty-appkit-defaults-standard-tests-\(UUID().uuidString)"
        let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: isolatedSuiteName))
        let standardDefaults = try XCTUnwrap(UserDefaults(suiteName: standardSuiteName))
        isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
        standardDefaults.removePersistentDomain(forName: standardSuiteName)
        defer {
            isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
            standardDefaults.removePersistentDomain(forName: standardSuiteName)
        }

        AppKitDefaultPreferences.apply(to: isolatedDefaults, standardDefaults: standardDefaults)

        XCTAssertEqual(
            isolatedDefaults.integer(forKey: AppKitDefaultPreferences.initialToolTipDelayKey),
            AppKitDefaultPreferences.initialToolTipDelayMilliseconds
        )
        XCTAssertEqual(
            standardDefaults.integer(forKey: AppKitDefaultPreferences.initialToolTipDelayKey),
            AppKitDefaultPreferences.initialToolTipDelayMilliseconds
        )
        XCTAssertEqual(
            isolatedDefaults.bool(forKey: AppKitDefaultPreferences.applePersistenceIgnoreStateKey),
            true
        )
        XCTAssertEqual(
            isolatedDefaults.bool(forKey: AppKitDefaultPreferences.quitAlwaysKeepsWindowsKey),
            false
        )
        XCTAssertNil(
            standardDefaults.persistentDomain(forName: standardSuiteName)?[
                AppKitDefaultPreferences.applePersistenceIgnoreStateKey
            ]
        )
        XCTAssertNil(
            standardDefaults.persistentDomain(forName: standardSuiteName)?[
                AppKitDefaultPreferences.quitAlwaysKeepsWindowsKey
            ]
        )
    }

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
