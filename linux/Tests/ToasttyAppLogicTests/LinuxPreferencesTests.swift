import CoreState
import Foundation
import Testing
@testable import ToasttyAppLogic

/// The Preferences dialog's Default Font Size writes `terminal-font-size`
/// into the Toastty config, keeping everything else in the file, and the
/// result reads back through `ToasttyConfigStore`.
@Suite(.serialized)
struct LinuxPreferencesTests {
    @Test func settingTheFontSizeUncommentsTheTemplateExampleInPlace() {
        let template = """
        # Toastty config

        # terminal-font-size sets the default font size baseline for Toastty.
        # terminal-font-size = 13

        # default-terminal-profile = "zmx"

        """
        let updated = LinuxToasttyConfigFileEditor.settingValue("16", forKey: "terminal-font-size", in: template)
        #expect(updated == """
        # Toastty config

        # terminal-font-size sets the default font size baseline for Toastty.
        # terminal-font-size = 13
        terminal-font-size = 16

        # default-terminal-profile = "zmx"

        """)
        // A second change replaces the active line.
        let again = LinuxToasttyConfigFileEditor.settingValue("12.50", forKey: "terminal-font-size", in: updated)
        #expect(again.components(separatedBy: "\n").filter { $0.hasPrefix("terminal-font-size") } == ["terminal-font-size = 12.50"])
    }

    @Test func settingTheFontSizeReplacesActiveLinesAndKeepsOthers() {
        let config = """
        default-terminal-profile = "zmx"
          terminal-font-size=10 # mine
        agent-hook = "~/hook.sh"
        """
        let updated = LinuxToasttyConfigFileEditor.settingValue("14", forKey: "terminal-font-size", in: config)
        #expect(updated == "default-terminal-profile = \"zmx\"\nterminal-font-size = 14\nagent-hook = \"~/hook.sh\"\n")
        #expect(LinuxToasttyConfigFileEditor.settingValue("14", forKey: "terminal-font-size", in: "") == "terminal-font-size = 14\n")
        #expect(LinuxToasttyConfigFileEditor.formatted(points: 14) == "14")
        #expect(LinuxToasttyConfigFileEditor.formatted(points: 13.5) == "13.50")
    }

    @Test func fontSizeWrittenToAnIsolatedRuntimeHomeLoadsBack() throws {
        let runtimeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-prefs-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: runtimeHome) }
        var environment = ProcessInfo.processInfo.environment
        environment["TOASTTY_RUNTIME_HOME"] = runtimeHome.path

        try LinuxToasttyConfigFileEditor.setTerminalFontSize(points: 18, environment: environment)
        #expect(ToasttyConfigStore.load(environment: environment).terminalFontSizePoints == 18)
        try LinuxToasttyConfigFileEditor.setTerminalFontSize(points: 9, environment: environment)
        #expect(ToasttyConfigStore.load(environment: environment).terminalFontSizePoints == 9)
        // Written into the template, so the commented reference stays.
        let contents = try String(contentsOf: runtimeHome.appendingPathComponent("config"), encoding: .utf8)
        #expect(contents.hasPrefix("# Toastty config"))
    }
}
