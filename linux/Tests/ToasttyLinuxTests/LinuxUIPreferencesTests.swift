import CoreState
import Foundation
import Testing
@testable import ToasttyLinuxUI

/// `LinuxUIPreferences` loads from and writes through to its storage
/// (style changes need a display and are covered by the Broadway restart
/// test, `PreferencesPersistenceTests`).
@MainActor
struct LinuxUIPreferencesTests {
    final class FakeStorage: LinuxUIPreferenceStorage {
        var askBeforeQuitting = true
        var values: [String: Any] = [:]
        var fontSizes: [Double] = []

        func setAskBeforeQuitting(_ value: Bool) { askBeforeQuitting = value }
        func bool(forKey key: String) -> Bool? { values[key] as? Bool }
        func string(forKey key: String) -> String? { values[key] as? String }
        func set(_ value: Bool, forKey key: String) { values[key] = value }
        func set(_ value: String, forKey key: String) { values[key] = value }
        func setDefaultTerminalFontSize(points: Double) { fontSizes.append(points) }
    }

    @Test func loadsStoredValuesAndWritesChangesThrough() {
        let storage = FakeStorage()
        storage.askBeforeQuitting = false
        storage.values = [
            LinuxUIPreferences.Key.colorScheme: "dark",
            LinuxUIPreferences.Key.showsShortcutHintsWithAlt: false,
            LinuxUIPreferences.Key.tabBarAutohide: true,
        ]
        let preferences = LinuxUIPreferences(storage: storage, environment: [:])
        #expect(preferences.colorScheme == .dark)
        #expect(preferences.askBeforeQuitting == false)
        #expect(preferences.showsShortcutHintsWithAlt == false)
        #expect(preferences.tabBarAutohide == true)

        preferences.askBeforeQuitting = true
        preferences.showsShortcutHintsWithAlt = true
        preferences.tabBarAutohide = false
        #expect(storage.askBeforeQuitting == true)
        #expect(storage.values[LinuxUIPreferences.Key.showsShortcutHintsWithAlt] as? Bool == true)
        #expect(storage.values[LinuxUIPreferences.Key.tabBarAutohide] as? Bool == false)

        // The shared setting is read live, so a change from elsewhere
        // (AppStore) is what the quit confirmation sees.
        storage.askBeforeQuitting = false
        #expect(preferences.askBeforeQuitting == false)

        preferences.setDefaultTerminalFontSize(points: 15, store: ReducerStoreBinding())
        #expect(storage.fontSizes == [15])
    }

    @Test func defaultsWithoutStoredValuesAndEnvironmentOverrideIsNotSaved() {
        let storage = FakeStorage()
        let preferences = LinuxUIPreferences(storage: storage, environment: ["TOASTTY_LINUX_COLOR_SCHEME": "light"])
        #expect(preferences.colorScheme == .light)
        #expect(preferences.askBeforeQuitting == true)
        #expect(preferences.showsShortcutHintsWithAlt == true)
        #expect(preferences.tabBarAutohide == false)
        #expect(storage.values.isEmpty)
    }

    @Test func withoutStorageTheyStayInMemory() {
        let preferences = LinuxUIPreferences(environment: [:])
        #expect(preferences.colorScheme == .system)
        preferences.askBeforeQuitting = false
        #expect(preferences.askBeforeQuitting == false)
        let store = ReducerStoreBinding()
        preferences.setDefaultTerminalFontSize(points: 16, store: store)
        #expect(store.state.configuredTerminalFontBaselinePoints == 16)
    }
}
