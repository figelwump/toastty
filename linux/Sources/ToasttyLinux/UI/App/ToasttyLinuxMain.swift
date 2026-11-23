import CGtk
import CoreState
import Foundation

public enum ToasttyLinuxMain {
    @MainActor
    public static func run(arguments: [String]) -> Int32 {
        GtkRendererSelection.initializeGtk()
        let environment = ProcessInfo.processInfo.environment
        let automation = AutomationScript.fromEnvironment()
        // The shared app reads the macOS automation flags (`--automation`,
        // `--run-id`, ...) from ProcessInfo; GApplication rejects options it
        // does not know, so they are removed from what it parses.
        let automationConfig = AutomationConfig.parse(arguments: arguments, environment: environment)
        let isAutomationSession = automationConfig != nil
        // A Broadway display with no viewer attached never ticks the frame
        // clock, so animations stay pending until a widget unmaps and
        // libadwaita's tab bar then finishes them against stale state (a
        // crash in its close-animation callback). Automation runs ask for no
        // animations, as on macOS.
        if automationConfig?.disableAnimations == true || environment["GDK_BACKEND"] == "broadway",
           let settings = gtk_settings_get_default() {
            GProperty.setBool(settings, "gtk-enable-animations", false)
        }
        let arguments = AutomationConfig.removingAutomationArguments(from: arguments)
        // Automation and runtime-isolated runs are separate instances; a
        // unique launch would be handed over D-Bus to the installed app.
        let nonUnique = automation != nil
            || isAutomationSession
            || ToasttyRuntimePaths.resolve(environment: environment).isRuntimeHomeEnabled
            || environment["TOASTTY_LINUX_NON_UNIQUE"] == "1"
        #if TOASTTY_LINUX_APP_LOGIC
        // The real app layer; TOASTTY_LINUX_REDUCER_STORE=1 keeps the
        // reducer-only binding (layout demos, UI debugging).
        if environment["TOASTTY_LINUX_REDUCER_STORE"] != "1" {
            let status = runWithAppLogic(arguments: arguments, automation: automation, nonUnique: nonUnique)
            if AutomationScript.failures.isEmpty == false {
                FileHandle.standardError.write(Data("toastty-linux: \(AutomationScript.failures.count) automation failure(s)\n".utf8))
                return 1
            }
            return status
        }
        #endif
        let sessions: (any LinuxSessionSource)? = environment["TOASTTY_LINUX_DEMO_SESSIONS"] == "1" ? DemoSessionSource() : nil
        let store = ReducerStoreBinding(state: .bootstrap(), sessions: sessions)
        if let demo = sessions as? DemoSessionSource { demo.attach(to: store) }

        let app = LinuxAppController(store: store, nonUnique: nonUnique)
        app.automation = automation
        app.installWebPanels()
        app.installTerminals()
        let status = app.run(arguments: arguments)
        if AutomationScript.failures.isEmpty == false {
            FileHandle.standardError.write(Data("toastty-linux: \(AutomationScript.failures.count) automation failure(s)\n".utf8))
            return 1
        }
        return status
    }
}
