import CoreState
import Foundation

// MARK: - Preferences (the GTK Preferences dialog's stores)

/// Where the GTK shell's Preferences settings persist, so a value set on
/// Linux is the one the shared code reads:
///
/// - Ask Before Quitting: `AppStore.askBeforeQuitting`, persisted by
///   `ToasttySettingsStore` as `toastty.askBeforeQuitting` (the macOS menu
///   toggle's path).
/// - Default Font Size: `terminal-font-size` in the Toastty config file
///   (`~/.toastty/config`, or the isolated runtime home's), which macOS and
///   Linux both read at startup and on Reload Configuration.
/// - Linux-only settings (no macOS equivalent): `ToasttyAppDefaults.current`
///   under `toastty.linux.*` keys chosen by the frontend.
///
/// Like `AppStore`'s own settings, automation sessions neither read nor
/// write any of these, so scripted runs start from defaults and never touch
/// a real profile.
extension LinuxAppLogic {
    public var askBeforeQuitting: Bool { store.askBeforeQuitting }

    public func setAskBeforeQuitting(_ askBeforeQuitting: Bool) {
        store.setAskBeforeQuitting(askBeforeQuitting)
    }

    /// Whether preferences are read from and written to disk (false in
    /// automation sessions, as `AppStore`'s `persistUserSettings`).
    public var persistsPreferences: Bool { isAutomationMode == false }

    public func linuxPreferenceBool(forKey key: String) -> Bool? {
        guard persistsPreferences else { return nil }
        switch ToasttyAppDefaults.current.object(forKey: key) {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        default: return nil
        }
    }

    public func linuxPreferenceString(forKey key: String) -> String? {
        guard persistsPreferences else { return nil }
        return ToasttyAppDefaults.current.string(forKey: key)
    }

    /// `ToasttyAppDefaults.current` writes through to disk on Linux.
    public func setLinuxPreference(_ value: Bool, forKey key: String) {
        guard persistsPreferences else { return }
        ToasttyAppDefaults.current.set(value, forKey: key)
    }

    public func setLinuxPreference(_ value: String, forKey key: String) {
        guard persistsPreferences else { return }
        ToasttyAppDefaults.current.set(value, forKey: key)
    }

    /// Sets the default terminal font size (the configured baseline) and
    /// writes it to the config file's `terminal-font-size`, which startup,
    /// Reload Configuration and Ghostty config loads re-apply; without the
    /// write those would reset the value.
    public func setDefaultTerminalFontSize(points: Double) {
        let clamped = AppState.clampedTerminalFontPoints(points)
        send(.setConfiguredTerminalFont(points: clamped))
        guard persistsPreferences else { return }
        do {
            try LinuxToasttyConfigFileEditor.setTerminalFontSize(points: clamped)
        } catch {
            ToasttyLog.warning(
                "Failed to write terminal-font-size to the Toastty config",
                category: .bootstrap,
                metadata: [
                    "path": ToasttyConfigStore.configFileURL().path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }
}

/// Line-level edits to the user's Toastty config file that keep every other
/// line (comments, other keys) as written. macOS has no settings UI for
/// these keys, so `ToasttyConfigStore` only renders templates.
enum LinuxToasttyConfigFileEditor {
    /// `ToasttyConfigStore.terminalFontSizeKey`.
    static let terminalFontSizeKey = "terminal-font-size"

    static func setTerminalFontSize(
        points: Double,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let url = ToasttyConfigStore.configFileURL(homeDirectoryPath: homeDirectoryPath, environment: environment)
        if FileManager.default.fileExists(atPath: url.path) == false {
            // The commented template, as a first launch writes it.
            try? ToasttyConfigStore.ensureTemplateExists(homeDirectoryPath: homeDirectoryPath, environment: environment)
        }
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = settingValue(formatted(points: points), forKey: terminalFontSizeKey, in: existing)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(updated.utf8).write(to: url, options: .atomic)
    }

    /// Replaces every active `key = ...` line (the parser keeps the last
    /// one); with none, uncomments the template's `# key = ...` example in
    /// place, else appends.
    static func settingValue(_ value: String, forKey key: String, in contents: String) -> String {
        var lines = contents.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let assignment = "\(key) = \(value)"
        var replaced = false
        for index in lines.indices where activeKey(of: lines[index]) == key {
            lines[index] = assignment
            replaced = true
        }
        if replaced == false {
            if let example = lines.lastIndex(where: { commentedKey(of: $0) == key }) {
                lines.insert(assignment, at: example + 1)
            } else {
                lines.append(assignment)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `ToasttyConfigStore.format(points:)`.
    static func formatted(points: Double) -> String {
        if abs(points.rounded() - points) < AppState.terminalFontComparisonEpsilon {
            return String(Int(points.rounded()))
        }
        return String(format: "%.2f", points)
    }

    private static func activeKey(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") == false, let separator = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<separator].trimmingCharacters(in: .whitespaces)
    }

    private static func commentedKey(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        return activeKey(of: String(trimmed.drop(while: { $0 == "#" || $0 == " " })))
    }
}
