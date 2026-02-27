import SwiftUI

@main
struct ToasttyApp: App {
    @StateObject private var store: AppStore
    private let automationLifecycle: AutomationLifecycle?
    private let disableAnimations: Bool

    init() {
        let bootstrap = AppBootstrap.make()
        _store = StateObject(wrappedValue: AppStore(state: bootstrap.state))
        automationLifecycle = bootstrap.automationLifecycle
        disableAnimations = bootstrap.disableAnimations
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(
                store: store,
                automationLifecycle: automationLifecycle,
                disableAnimations: disableAnimations
            )
                .frame(minWidth: 980, minHeight: 620)
        }
    }
}
