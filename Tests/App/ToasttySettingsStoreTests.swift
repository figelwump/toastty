@testable import ToasttyApp
import XCTest

final class ToasttySettingsStoreTests: XCTestCase {
    func testLoadDefaultsHasEverLaunchedAgentToFalse() {
        let userDefaults = makeUserDefaults()

        let settings = ToasttySettingsStore.load(userDefaults: userDefaults)

        XCTAssertFalse(settings.hasEverLaunchedAgent)
    }

    func testPersistHasEverLaunchedAgentStoresAndLoadsFlag() {
        let userDefaults = makeUserDefaults()

        ToasttySettingsStore.persistHasEverLaunchedAgent(true, userDefaults: userDefaults)
        let settings = ToasttySettingsStore.load(userDefaults: userDefaults)

        XCTAssertTrue(settings.hasEverLaunchedAgent)
    }

    func testPersistTerminalFontSizePointsStoresAndLoadsOverride() {
        let userDefaults = makeUserDefaults()

        ToasttySettingsStore.persistTerminalFontSizePoints(13.5, userDefaults: userDefaults)
        let settings = ToasttySettingsStore.load(userDefaults: userDefaults)

        XCTAssertEqual(settings.terminalFontSizePoints, 13.5)
    }

    func testPersistTerminalFontSizePointsClearsStoredOverride() {
        let userDefaults = makeUserDefaults()
        ToasttySettingsStore.persistTerminalFontSizePoints(16, userDefaults: userDefaults)

        ToasttySettingsStore.persistTerminalFontSizePoints(nil, userDefaults: userDefaults)
        let settings = ToasttySettingsStore.load(userDefaults: userDefaults)

        XCTAssertNil(settings.terminalFontSizePoints)
    }

    func testPersistTerminalFontSizePointsClampsStoredOverride() {
        let userDefaults = makeUserDefaults()

        ToasttySettingsStore.persistTerminalFontSizePoints(100, userDefaults: userDefaults)
        let settings = ToasttySettingsStore.load(userDefaults: userDefaults)

        XCTAssertEqual(settings.terminalFontSizePoints, 24)
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "toastty-settings-store-tests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }
}
