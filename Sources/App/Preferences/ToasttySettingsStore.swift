import CoreState
import Foundation

struct ToasttySettings: Equatable {
    var terminalFontSizePoints: Double? = nil
    /// One-way app-wide latch for sidebar defaults after the first successful agent launch.
    var hasEverLaunchedAgent = false
}

enum ToasttySettingsStore {
    private static let terminalFontSizeKey = "toastty.terminalFontSizePoints"
    private static let hasEverLaunchedAgentKey = "toastty.hasEverLaunchedAgent"

    static func load(userDefaults: UserDefaults = .standard) -> ToasttySettings {
        let terminalFontSizePoints = loadTerminalFontSizePoints(userDefaults: userDefaults)
        return ToasttySettings(
            terminalFontSizePoints: terminalFontSizePoints,
            hasEverLaunchedAgent: loadHasEverLaunchedAgent(userDefaults: userDefaults)
        )
    }

    static func persistTerminalFontSizePoints(
        _ points: Double?,
        userDefaults: UserDefaults = .standard
    ) {
        let clampedPoints = points.map(AppState.clampedTerminalFontPoints)
        if let clampedPoints {
            userDefaults.set(clampedPoints, forKey: terminalFontSizeKey)
        } else {
            userDefaults.removeObject(forKey: terminalFontSizeKey)
        }
    }

    static func persistHasEverLaunchedAgent(
        _ hasEverLaunchedAgent: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(hasEverLaunchedAgent, forKey: hasEverLaunchedAgentKey)
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
}
