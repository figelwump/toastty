import SwiftUI

struct AppRootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let automationLifecycle: AutomationLifecycle?
    let automationStartupError: String?
    let disableAnimations: Bool

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store)
                .frame(width: 200)
            Divider()
            WorkspaceView(store: store, terminalRuntimeRegistry: terminalRuntimeRegistry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            terminalRuntimeRegistry.synchronize(with: store.state)
            automationLifecycle?.markReady(runtimeError: automationStartupError)
        }
        .onChange(of: store.state) { _, nextState in
            terminalRuntimeRegistry.synchronize(with: nextState)
        }
        .transaction { transaction in
            if disableAnimations {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }
}
