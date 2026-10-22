import CoreState
import Foundation

struct ToasttySettings: Equatable {
    /// When false, Cmd+Q quits immediately without checking terminal activity.
    var askBeforeQuitting = true
    /// What a subspace's Merge button and shortcut do.
    var workspaceMergeMode = WorkspaceMergeMode.mergeAndCleanUp
    /// Hidden flag for the subspace Merge button, its context menu items, and
    /// its shortcut. Off until task lifecycle hooks replace it; there is no
    /// settings UI, so turn it on by writing the defaults key.
    var isWorkspaceMergeEnabled = false
}

enum ToasttySettingsStore {
    private static let terminalFontSizeKey = "toastty.terminalFontSizePoints"
    /// No longer written. Older builds set it after the first agent launch,
    /// so it still marks an existing install for Getting Started.
    private static let legacyHasEverLaunchedAgentKey = "toastty.hasEverLaunchedAgent"
    private static let askBeforeQuittingKey = "toastty.askBeforeQuitting"
    private static let workspaceMergeModeKey = "toastty.workspaceMergeMode"
    private static let workspaceMergeEnabledKey = "toastty.workspaceMergeEnabled"

    static func load(userDefaults: UserDefaults = ToasttyAppDefaults.current) -> ToasttySettings {
        return ToasttySettings(
            askBeforeQuitting: loadAskBeforeQuitting(userDefaults: userDefaults),
            workspaceMergeMode: userDefaults.string(forKey: workspaceMergeModeKey)
                .flatMap(WorkspaceMergeMode.init(rawValue:)) ?? .mergeAndCleanUp,
            isWorkspaceMergeEnabled: userDefaults.bool(forKey: workspaceMergeEnabledKey)
        )
    }

    static func hasPersistedSettings(userDefaults: UserDefaults = ToasttyAppDefaults.current) -> Bool {
        for key in [
            terminalFontSizeKey,
            legacyHasEverLaunchedAgentKey,
            askBeforeQuittingKey,
        ] where userDefaults.object(forKey: key) != nil {
            return true
        }
        return false
    }

    static func legacyTerminalFontSizePoints(
        userDefaults: UserDefaults = ToasttyAppDefaults.current
    ) -> Double? {
        loadTerminalFontSizePoints(userDefaults: userDefaults)
    }

    static func clearLegacyTerminalFontSizePoints(userDefaults: UserDefaults = ToasttyAppDefaults.current) {
        userDefaults.removeObject(forKey: terminalFontSizeKey)
    }

    static func persistAskBeforeQuitting(
        _ askBeforeQuitting: Bool,
        userDefaults: UserDefaults = ToasttyAppDefaults.current
    ) {
        userDefaults.set(askBeforeQuitting, forKey: askBeforeQuittingKey)
    }

    static func persistWorkspaceMergeMode(
        _ mode: WorkspaceMergeMode,
        userDefaults: UserDefaults = ToasttyAppDefaults.current
    ) {
        userDefaults.set(mode.rawValue, forKey: workspaceMergeModeKey)
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
