import CoreState
import Foundation

struct ToasttySettings: Equatable {
    var terminalFontSizePoints: Double?
}

enum ToasttySettingsStore {
    private static let terminalFontSizeKey = "toastty.terminalFontSizePoints"

    static func load(userDefaults: UserDefaults = ToasttyAppDefaults.current) -> ToasttySettings {
        let terminalFontSizePoints = loadTerminalFontSizePoints(userDefaults: userDefaults)
        return ToasttySettings(terminalFontSizePoints: terminalFontSizePoints)
    }

    static func persistTerminalFontSizePoints(
        _ points: Double?,
        userDefaults: UserDefaults = ToasttyAppDefaults.current
    ) {
        let clampedPoints = points.map(AppState.clampedTerminalFontPoints)
        if let clampedPoints {
            userDefaults.set(clampedPoints, forKey: terminalFontSizeKey)
        } else {
            userDefaults.removeObject(forKey: terminalFontSizeKey)
        }
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
}
