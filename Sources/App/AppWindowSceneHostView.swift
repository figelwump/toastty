import CoreState
import SwiftUI

enum AppWindowSceneDismissalPolicy {
    static func shouldDismissSceneAfterLosingBoundWindow(
        previouslyHadBoundWindow: Bool,
        remainingWindowCount: Int,
        closeWasRequested: Bool
    ) -> Bool {
        guard previouslyHadBoundWindow else { return false }
        if remainingWindowCount > 0 {
            return true
        }
        return closeWasRequested
    }
}

struct AppWindowSceneBindingState: Equatable {
    var boundWindowID: UUID?
    var hasBoundWindow: Bool
    var sceneWindowIDValue: String?
    var shouldDismissAfterNextBindingLoss: Bool
}

struct AppWindowSceneBindingLossResolution: Equatable {
    let nextState: AppWindowSceneBindingState
    let shouldDismissScene: Bool
}

enum AppWindowSceneBindingLossResolver {
    static func resolve(
        previouslyHadBoundWindow: Bool,
        remainingWindowCount: Int,
        closeWasRequested: Bool
    ) -> AppWindowSceneBindingLossResolution {
        let shouldDismissScene = AppWindowSceneDismissalPolicy.shouldDismissSceneAfterLosingBoundWindow(
            previouslyHadBoundWindow: previouslyHadBoundWindow,
            remainingWindowCount: remainingWindowCount,
            closeWasRequested: closeWasRequested
        )
        return AppWindowSceneBindingLossResolution(
            nextState: AppWindowSceneBindingState(
                boundWindowID: nil,
                hasBoundWindow: false,
                sceneWindowIDValue: nil,
                shouldDismissAfterNextBindingLoss: false
            ),
            shouldDismissScene: shouldDismissScene
        )
    }
}

struct AppWindowSceneHostView: View {
    @Binding var sceneWindowID: UUID?
    @ObservedObject var store: AppStore
    @ObservedObject var agentCatalogStore: AgentCatalogStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let profileShortcutRegistry: ProfileShortcutRegistry
    let agentLaunchService: AgentLaunchService
    let openAgentProfilesConfiguration: () -> Void
    let sceneCoordinator: AppWindowSceneCoordinator
    let automationLifecycle: AutomationLifecycle?
    let automationStartupError: String?
    let disableAnimations: Bool

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    // The scene's value keeps the WindowGroup instance associated with a
    // specific app window ID while local state drives immediate rebinding.
    @State private var boundWindowID: UUID?
    @State private var hasBoundWindow = false
    @State private var shouldDismissAfterNextBindingLoss = false

    private var stateWindowIDs: [UUID] {
        store.state.windows.map(\.id)
    }

    var body: some View {
        Group {
            if let boundWindowID {
                AppWindowSceneView(
                    windowID: boundWindowID,
                    store: store,
                    agentCatalogStore: agentCatalogStore,
                    terminalProfileStore: terminalProfileStore,
                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                    sessionRuntimeStore: sessionRuntimeStore,
                    sceneCoordinator: sceneCoordinator,
                    profileShortcutRegistry: profileShortcutRegistry,
                    agentLaunchService: agentLaunchService,
                    openAgentProfilesConfiguration: openAgentProfilesConfiguration,
                    onWindowCloseInitiated: handleWindowCloseInitiated,
                    disableAnimations: disableAnimations
                )
            } else {
                EmptyStateView(onCreateWorkspace: createWorkspaceAction)
            }
        }
        .onAppear {
            synchronizeSceneBinding()
        }
        .onChange(of: stateWindowIDs) { _, _ in
            synchronizeSceneBinding()
        }
        .onDisappear {
            guard let boundWindowID else { return }
            sceneCoordinator.unregisterPresentedWindow(windowID: boundWindowID)
        }
    }

    private func synchronizeSceneBinding() {
        if boundWindowID == nil {
            boundWindowID = sceneWindowID
        }

        if let boundWindowID, store.window(id: boundWindowID) != nil {
            hasBoundWindow = true
            registerPresentedWindow(boundWindowID)
            persistWindowID(boundWindowID)
            automationLifecycle?.markReady(runtimeError: automationStartupError)
        } else if hasBoundWindow {
            let didConsumePanelCloseDismissalRequest =
                boundWindowID.map { sceneCoordinator.consumeSceneDismissalAfterBindingLoss(windowID: $0) } == true
            let closeWasRequested = shouldDismissAfterNextBindingLoss || didConsumePanelCloseDismissalRequest
            let resolution = AppWindowSceneBindingLossResolver.resolve(
                previouslyHadBoundWindow: hasBoundWindow,
                remainingWindowCount: store.state.windows.count,
                closeWasRequested: closeWasRequested
            )
            let dismissalWindowID = boundWindowID
            ToasttyLog.debug(
                "Scene lost bound window",
                category: .app,
                metadata: [
                    "bound_window_id": dismissalWindowID?.uuidString ?? "<none>",
                    "close_was_requested": closeWasRequested ? "true" : "false",
                    "should_dismiss_scene": resolution.shouldDismissScene ? "true" : "false",
                ]
            )
            if let boundWindowID {
                sceneCoordinator.unregisterPresentedWindow(windowID: boundWindowID)
            }
            if resolution.shouldDismissScene, let dismissalWindowID {
                let dismissWindow = self.dismissWindow
                ToasttyLog.debug(
                    "Requesting SwiftUI scene dismissal after bound window loss",
                    category: .app,
                    metadata: [
                        "window_id": dismissalWindowID.uuidString,
                    ]
                )
                Task { @MainActor in
                    dismissWindow(id: AppWindowSceneID.value, value: dismissalWindowID)
                }
                hasBoundWindow = resolution.nextState.hasBoundWindow
                shouldDismissAfterNextBindingLoss = resolution.nextState.shouldDismissAfterNextBindingLoss
                return
            }
            boundWindowID = resolution.nextState.boundWindowID
            hasBoundWindow = resolution.nextState.hasBoundWindow
            sceneWindowID = resolution.nextState.sceneWindowIDValue.flatMap(UUID.init(uuidString:))
            shouldDismissAfterNextBindingLoss = resolution.nextState.shouldDismissAfterNextBindingLoss
            return
        } else if let claimedWindowID = sceneCoordinator.claimWindowID(in: store.state) {
            bind(claimedWindowID)
        }

        let missingWindowIDs = sceneCoordinator.reserveMissingWindowIDs(
            in: store.state,
            excluding: Set(boundWindowID.map { [$0] } ?? [])
        )
        for windowID in missingWindowIDs {
            openWindow(id: AppWindowSceneID.value, value: windowID)
        }
    }

    private func bind(_ windowID: UUID) {
        boundWindowID = windowID
        hasBoundWindow = true
        registerPresentedWindow(windowID)
        persistWindowID(windowID)
        automationLifecycle?.markReady(runtimeError: automationStartupError)
    }

    private func persistWindowID(_ windowID: UUID) {
        guard sceneWindowID != windowID else { return }
        sceneWindowID = windowID
    }

    private func handleWindowCloseInitiated() {
        shouldDismissAfterNextBindingLoss = true
        guard let boundWindowID else { return }
        let dismissWindow = self.dismissWindow
        ToasttyLog.debug(
            "Requesting SwiftUI scene dismissal after close initiation",
            category: .app,
            metadata: [
                "window_id": boundWindowID.uuidString,
            ]
        )
        Task { @MainActor in
            dismissWindow(id: AppWindowSceneID.value, value: boundWindowID)
        }
    }

    private func registerPresentedWindow(_ windowID: UUID) {
        sceneCoordinator.registerPresentedWindow(windowID: windowID)
    }

    private var createWorkspaceAction: (() -> Void)? {
        guard store.canCreateWorkspaceFromCommand(preferredWindowID: nil) else { return nil }
        return {
            _ = store.createWorkspaceFromCommand(preferredWindowID: nil)
        }
    }
}
