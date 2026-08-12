import SwiftUI
import ToasttyMobileDomain

struct ToasttyMobileRootView: View {
    @State private var controller: HomeScreenController

    init(configuration: ToasttyMobileAppConfiguration) {
        _controller = State(initialValue: HomeScreenController(
            runtimeMode: configuration.runtimeMode,
            snapshot: configuration.initialSnapshot,
            connectionState: configuration.initialConnectionState
        ))
    }

    var body: some View {
        NavigationStack {
            ToasttyHomeView(controller: controller)
                .navigationDestination(for: UUID.self) { workspaceID in
                    if let workspace = controller.snapshot.workspaces.first(where: { $0.id == workspaceID }) {
                        ToasttyWorkspaceView(workspace: workspace, onOpen: controller.open)
                    }
                }
        }
        .tint(ToasttyDesignTokens.amber)
        .background(ToasttyDesignTokens.background.ignoresSafeArea())
        .sheet(item: $controller.selectedConversation) { conversation in
            ToasttyConversationSheet(
                conversation: conversation,
                onDismiss: controller.dismissConversation
            )
            .presentationDetents([.fraction(0.92)])
            .presentationDragIndicator(.visible)
            .presentationBackground(ToasttyDesignTokens.elevatedSurface)
        }
    }
}

#Preview("Fixture home") {
    ToasttyMobileRootView(configuration: ToasttyMobileAppConfiguration(
        environment: ["TOASTTY_MOBILE_USE_FIXTURE": "1"],
        infoDictionary: [:]
    ))
}
