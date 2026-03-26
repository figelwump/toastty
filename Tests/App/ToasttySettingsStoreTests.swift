@testable import ToasttyApp
import XCTest

final class ToasttySettingsStoreTests: XCTestCase {
    private let legacyTerminalFontSizeKey = "toastty.terminalFontSizePoints"

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

    func testLegacyTerminalFontSizePointsLoadsStoredOverride() {
        let userDefaults = makeUserDefaults()
        userDefaults.set(13.5, forKey: legacyTerminalFontSizeKey)

        XCTAssertEqual(
            ToasttySettingsStore.legacyTerminalFontSizePoints(userDefaults: userDefaults),
            13.5
        )
    }

    func testClearLegacyTerminalFontSizePointsRemovesStoredOverride() {
        let userDefaults = makeUserDefaults()
        userDefaults.set(16.0, forKey: legacyTerminalFontSizeKey)

        ToasttySettingsStore.clearLegacyTerminalFontSizePoints(userDefaults: userDefaults)

        XCTAssertNil(ToasttySettingsStore.legacyTerminalFontSizePoints(userDefaults: userDefaults))
    }

    func testLegacyTerminalFontSizePointsClampsStoredOverride() {
        let userDefaults = makeUserDefaults()
        userDefaults.set(100.0, forKey: legacyTerminalFontSizeKey)

        XCTAssertEqual(
            ToasttySettingsStore.legacyTerminalFontSizePoints(userDefaults: userDefaults),
            24
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "toastty-settings-store-tests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }
}
