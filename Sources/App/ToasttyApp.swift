import SwiftUI

@main
struct ToasttyApp: App {
    @StateObject private var store: AppStore
    private let automationLifecycle: AutomationLifecycle?
    private let automationSocketServer: AutomationSocketServer?
    private let automationStartupError: String?
    private let disableAnimations: Bool

    init() {
        let bootstrap = AppBootstrap.make()
        let store = AppStore(state: bootstrap.state)
        _store = StateObject(wrappedValue: store)
        automationLifecycle = bootstrap.automationLifecycle
        disableAnimations = bootstrap.disableAnimations

        if let automationConfig = bootstrap.automationConfig {
            do {
                automationSocketServer = try AutomationSocketServer(config: automationConfig, store: store)
                automationStartupError = nil
            } catch {
                automationSocketServer = nil
                automationStartupError = "Automation socket startup failed: \(error.localizedDescription)"
                if let messageData = ("toastty automation error: \(automationStartupError ?? "unknown")\n").data(using: .utf8) {
                    FileHandle.standardError.write(messageData)
                }
            }
        } else {
            automationSocketServer = nil
            automationStartupError = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(
                store: store,
                automationLifecycle: automationLifecycle,
                automationStartupError: automationStartupError,
                disableAnimations: disableAnimations
            )
                .frame(minWidth: 980, minHeight: 620)
        }
    }
}
