import Foundation
import Testing

/// Preferences dialog settings survive a restart. Change every setting
/// through the dialog's rows (Style, Ask Before Quitting, Shortcut Hints,
/// Default Font Size), quit as a user does, relaunch with the same home and
/// check the model, the applied style and the reopened dialog's rows; then
/// change them back and check that sticks too.
///
/// Each setting is stored where the shared code reads it: Ask Before
/// Quitting is `ToasttySettingsStore`'s `toastty.askBeforeQuitting` (so the
/// quit confirmation, `AppStore` and the switch agree), the font size is
/// `terminal-font-size` in the runtime home's `config`, and the Linux-only
/// Style and Shortcut Hints are `toastty.linux.*` app defaults.
///
/// Skip with `TOASTTY_LINUX_SKIP_GUI_TESTS=1`.
@Suite("Preferences persistence", .serialized)
struct PreferencesPersistenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOASTTY_LINUX_SKIP_GUI_TESTS"] != "1"))
    func preferencesSurviveRestart() throws {
        guard let harness = try RestartTestHarness(name: "prefs-persist") else { return }

        // 1. Defaults; change everything in the dialog, then close the
        // window. Ask Before Quitting is now off, so it quits without asking.
        try harness.run("change", """
        wait 300
        expect prefStyle=system appliedStyle=system prefAskBeforeQuitting=true sharedAskBeforeQuitting=true prefShortcutHints=true
        action app.preferences
        wait 300
        expect dialog=AdwPreferencesDialog prefsDialogStyle=system prefsDialogAskBeforeQuitting=true prefsDialogShortcutHints=true
        preferences style dark
        preferences ask-before-quitting off
        preferences shortcut-hints off
        preferences font-size 17
        expect prefStyle=dark appliedStyle=dark prefAskBeforeQuitting=false sharedAskBeforeQuitting=false prefShortcutHints=false defaultFontSize=17
        close-dialog
        window-close
        """)
        var stored = try harness.storedDefaults()
        #expect(stored["toastty.askBeforeQuitting"] as? Bool == false)
        #expect(stored["toastty.linux.colorScheme"] as? String == "dark")
        #expect(stored["toastty.linux.showsShortcutHintsWithAlt"] as? Bool == false)
        let config = try String(contentsOf: harness.runtimeHome.appendingPathComponent("config"), encoding: .utf8)
        #expect(config.split(separator: "\n").contains("terminal-font-size = 17"), "config:\n\(config)")

        // 2. Relaunch: all restored, in the model, the window and the dialog.
        // Change them back; Ask Before Quitting is on again, so Quit asks.
        try harness.run("restored", """
        wait 300
        expect prefStyle=dark appliedStyle=dark prefAskBeforeQuitting=false sharedAskBeforeQuitting=false prefShortcutHints=false defaultFontSize=17
        action app.preferences
        wait 300
        expect prefsDialogStyle=dark prefsDialogAskBeforeQuitting=false prefsDialogShortcutHints=false prefsDialogFontSize=17
        preferences style light
        preferences ask-before-quitting on
        preferences shortcut-hints on
        preferences font-size 11
        expect prefStyle=light appliedStyle=light prefAskBeforeQuitting=true sharedAskBeforeQuitting=true prefShortcutHints=true defaultFontSize=11
        close-dialog
        window-close
        expect dialog=AdwAlertDialog dialogDefault=confirm
        dialog-click confirm
        """)
        stored = try harness.storedDefaults()
        #expect(stored["toastty.askBeforeQuitting"] as? Bool == true)
        #expect(stored["toastty.linux.colorScheme"] as? String == "light")
        #expect(stored["toastty.linux.showsShortcutHintsWithAlt"] as? Bool == true)

        // 3. Relaunch: the second set sticks.
        try harness.run("reverted", """
        wait 300
        expect prefStyle=light appliedStyle=light prefAskBeforeQuitting=true sharedAskBeforeQuitting=true prefShortcutHints=true defaultFontSize=11
        action app.preferences
        wait 300
        expect prefsDialogStyle=light prefsDialogAskBeforeQuitting=true prefsDialogShortcutHints=true prefsDialogFontSize=11
        close-dialog
        quit
        """)
    }
}
