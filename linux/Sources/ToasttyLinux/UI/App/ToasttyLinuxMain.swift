import CGtk
import CoreState
import Foundation

public enum ToasttyLinuxMain {
    @MainActor
    public static func run(arguments: [String]) -> Int32 {
        GtkRendererSelection.initializeGtk()
        let environment = ProcessInfo.processInfo.environment
        let automation = AutomationScript.fromEnvironment()
        #if TOASTTY_LINUX_APP_LOGIC
        // The real app layer; TOASTTY_LINUX_REDUCER_STORE=1 keeps the
        // reducer-only binding (layout demos, UI debugging).
        if environment["TOASTTY_LINUX_REDUCER_STORE"] != "1" {
            let nonUnique = automation != nil || environment["TOASTTY_LINUX_NON_UNIQUE"] == "1"
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

        let nonUnique = automation != nil || environment["TOASTTY_LINUX_NON_UNIQUE"] == "1"
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
