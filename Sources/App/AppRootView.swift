import SwiftUI

struct AppRootView: View {
    @ObservedObject var store: AppStore
    let automationLifecycle: AutomationLifecycle?
    let disableAnimations: Bool

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store)
                .frame(width: 200)
            Divider()
            WorkspaceView(store: store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            automationLifecycle?.markReady()
        }
        .transaction { transaction in
            if disableAnimations {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }
}
