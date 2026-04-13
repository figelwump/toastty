import CoreState
import Foundation

struct ToasttySettings: Equatable {
    /// One-way app-wide latch for sidebar defaults after the first successful agent launch.
    var hasEverLaunchedAgent = false
    /// When false, Cmd+Q quits immediately without checking terminal activity.
    var askBeforeQuitting = true
}

enum ToasttySettingsStore {
    private static let terminalFontSizeKey = "toastty.terminalFontSizePoints"
    private static let hasEverLaunchedAgentKey = "toastty.hasEverLaunchedAgent"
    private static let askBeforeQuittingKey = "toastty.askBeforeQuitting"

    static func load(userDefaults: UserDefaults = ToasttyAppDefaults.current) -> ToasttySettings {
        return ToasttySettings(
            hasEverLaunchedAgent: loadHasEverLaunchedAgent(userDefaults: userDefaults),
            askBeforeQuitting: loadAskBeforeQuitting(userDefaults: userDefaults)
        )
    }

    static func legacyTerminalFontSizePoints(
        userDefaults: UserDefaults = ToasttyAppDefaults.current
    ) -> Double? {
        loadTerminalFontSizePoints(userDefaults: userDefaults)
    }

    static func clearLegacyTerminalFontSizePoints(userDefaults: UserDefaults = ToasttyAppDefaults.current) {
        userDefaults.removeObject(forKey: terminalFontSizeKey)
    }

    static func persistHasEverLaunchedAgent(
        _ hasEverLaunchedAgent: Bool,
        userDefaults: UserDefaults = ToasttyAppDefaults.current
    ) {
        userDefaults.set(hasEverLaunchedAgent, forKey: hasEverLaunchedAgentKey)
    }

    static func persistAskBeforeQuitting(
        _ askBeforeQuitting: Bool,
        userDefaults: UserDefaults = ToasttyAppDefaults.current
    ) {
        userDefaults.set(askBeforeQuitting, forKey: askBeforeQuittingKey)
    }

    private static func loadTerminalFontSizePoints(userDefaults: UserDefaults) -> Double? {
        guard let storedValue = userDefaults.object(forKey: terminalFontSizeKey) else {
            return nil
        }

        switch storedValue {
        case let points as Double:
            return AppState.clampedTerminalFontPoints(points)
        case let points as NSNumber:
            return AppState.clampedTerminalFontPoints(points.doubleValue)
        default:
            return nil
        }
    }

    private static func loadHasEverLaunchedAgent(userDefaults: UserDefaults) -> Bool {
        guard let storedValue = userDefaults.object(forKey: hasEverLaunchedAgentKey) else {
            return false
        }

        switch storedValue {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        default:
            return false
        }
    }

    private static func loadAskBeforeQuitting(userDefaults: UserDefaults) -> Bool {
        guard let storedValue = userDefaults.object(forKey: askBeforeQuittingKey) else {
            return true
        }

        switch storedValue {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        default:
            return true
        }
    }
}
