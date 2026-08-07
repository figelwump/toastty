@testable import ToasttyApp
import XCTest

final class ToasttySettingsStoreTests: XCTestCase {
    private let legacyTerminalFontSizeKey = "toastty.terminalFontSizePoints"

    func testLoadDefaultsHasEverLaunchedAgentToFalse() {
        let userDefaults = makeUserDefaults()

        let settings = ToasttySettingsStore.load(userDefaults: userDefaults)

        XCTAssertFalse(settings.hasEverLaunchedAgent)
        XCTAssertTrue(settings.askBeforeQuitting)
        XCTAssertFalse(ToasttySettingsStore.hasPersistedSettings(userDefaults: userDefaults))
    }

    func testPersistHasEverLaunchedAgentStoresAndLoadsFlag() {
        let userDefaults = makeUserDefaults()

        ToasttySettingsStore.persistHasEverLaunchedAgent(true, userDefaults: userDefaults)
        let settings = ToasttySettingsStore.load(userDefaults: userDefaults)

        XCTAssertTrue(settings.hasEverLaunchedAgent)
        XCTAssertTrue(settings.askBeforeQuitting)
        XCTAssertTrue(ToasttySettingsStore.hasPersistedSettings(userDefaults: userDefaults))
    }

    func testPersistAskBeforeQuittingStoresAndLoadsFlag() {
        let userDefaults = makeUserDefaults()

        ToasttySettingsStore.persistAskBeforeQuitting(false, userDefaults: userDefaults)
        let settings = ToasttySettingsStore.load(userDefaults: userDefaults)

        XCTAssertFalse(settings.askBeforeQuitting)
        XCTAssertFalse(settings.hasEverLaunchedAgent)
        XCTAssertTrue(ToasttySettingsStore.hasPersistedSettings(userDefaults: userDefaults))
    }

    func testAppKitDefaultPreferencesDoNotCountAsToasttyPersistedSettings() {
        let userDefaults = makeUserDefaults()

        AppKitDefaultPreferences.apply(to: userDefaults, standardDefaults: userDefaults)

        XCTAssertFalse(ToasttySettingsStore.hasPersistedSettings(userDefaults: userDefaults))
    }

    func testLegacyTerminalFontSizePointsLoadsStoredOverride() {
        let userDefaults = makeUserDefaults()
        userDefaults.set(13.5, forKey: legacyTerminalFontSizeKey)

        XCTAssertEqual(
            ToasttySettingsStore.legacyTerminalFontSizePoints(userDefaults: userDefaults),
            13.5
        )
        XCTAssertTrue(ToasttySettingsStore.hasPersistedSettings(userDefaults: userDefaults))
    }

    func testClearLegacyTerminalFontSizePointsRemovesStoredOverride() {
        let userDefaults = makeUserDefaults()
        userDefaults.set(16.0, forKey: legacyTerminalFontSizeKey)

        ToasttySettingsStore.clearLegacyTerminalFontSizePoints(userDefaults: userDefaults)

        XCTAssertNil(ToasttySettingsStore.legacyTerminalFontSizePoints(userDefaults: userDefaults))
        XCTAssertFalse(ToasttySettingsStore.hasPersistedSettings(userDefaults: userDefaults))
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
