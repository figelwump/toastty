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
        // When the last state-backed window disappears, only the explicit
        // native close path should tear the scene down. Otherwise SwiftUI can
        // keep the scene alive and fall back to the global empty state.
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
    @ObservedObject var store: AppStore
    @ObservedObject var agentCatalogStore: AgentCatalogStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let profileShortcutRegistry: ProfileShortcutRegistry
    let focusedPanelCommandController: FocusedPanelCommandController
    let agentLaunchService: AgentLaunchService
    let openAgentProfilesConfigurationResult: @MainActor () -> Result<Void, AgentGetStartedActionError>
    let openKeyboardShortcutsReferenceResult: @MainActor () -> Result<Void, AgentGetStartedActionError>
    let toggleCommandPalette: @MainActor (UUID) -> Void
    let sceneCoordinator: AppWindowSceneCoordinator
    let automationLifecycle: AutomationLifecycle?
    let automationStartupError: String?
    let disableAnimations: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("toastty.window-id") private var sceneWindowIDValue: String?
    // SceneStorage keeps the scene/window association across relaunches, while
    // local state drives immediate rendering and rebinding during startup.
    @State private var boundWindowID: UUID?
    @State private var hasBoundWindow = false
    @State private var restoredStoredWindowID = false
    @State private var shouldDismissAfterNextBindingLoss = false

    private var storedSceneWindowID: UUID? {
        sceneWindowIDValue.flatMap(UUID.init(uuidString:))
    }

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
                    webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                    sessionRuntimeStore: sessionRuntimeStore,
                    profileShortcutRegistry: profileShortcutRegistry,
                    focusedPanelCommandController: focusedPanelCommandController,
                    agentLaunchService: agentLaunchService,
                    openAgentProfilesConfigurationResult: openAgentProfilesConfigurationResult,
                    openKeyboardShortcutsReferenceResult: openKeyboardShortcutsReferenceResult,
                    toggleCommandPalette: toggleCommandPalette,
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
        if restoredStoredWindowID == false {
            restoredStoredWindowID = true
            boundWindowID = storedSceneWindowID
        }

        if let boundWindowID, store.window(id: boundWindowID) != nil {
            hasBoundWindow = true
            sceneCoordinator.registerPresentedWindow(windowID: boundWindowID)
            persistWindowID(boundWindowID)
            automationLifecycle?.markReady(runtimeError: automationStartupError)
        } else if hasBoundWindow {
            let resolution = AppWindowSceneBindingLossResolver.resolve(
                previouslyHadBoundWindow: hasBoundWindow,
                remainingWindowCount: store.state.windows.count,
                closeWasRequested: shouldDismissAfterNextBindingLoss
            )
            if let boundWindowID {
                sceneCoordinator.unregisterPresentedWindow(windowID: boundWindowID)
            }
            boundWindowID = resolution.nextState.boundWindowID
            hasBoundWindow = resolution.nextState.hasBoundWindow
            sceneWindowIDValue = resolution.nextState.sceneWindowIDValue
            shouldDismissAfterNextBindingLoss = resolution.nextState.shouldDismissAfterNextBindingLoss
            if resolution.shouldDismissScene {
                // A user explicitly closed this window, so dismiss the scene
                // even when it was the last bound window in app state.
                dismiss()
            }
            return
        } else if let claimedWindowID = sceneCoordinator.claimWindowID(in: store.state) {
            bind(claimedWindowID)
        }

        let missingWindowIDs = sceneCoordinator.reserveMissingWindowIDs(
            in: store.state,
            excluding: Set(boundWindowID.map { [$0] } ?? [])
        )
        for _ in missingWindowIDs {
            openWindow(id: AppWindowSceneID.value)
        }
    }

    private func bind(_ windowID: UUID) {
        boundWindowID = windowID
        hasBoundWindow = true
        sceneCoordinator.registerPresentedWindow(windowID: windowID)
        persistWindowID(windowID)
        automationLifecycle?.markReady(runtimeError: automationStartupError)
    }

    private func persistWindowID(_ windowID: UUID) {
        let persistedValue = windowID.uuidString
        guard sceneWindowIDValue != persistedValue else { return }
        sceneWindowIDValue = persistedValue
    }

    private func handleWindowCloseInitiated() {
        shouldDismissAfterNextBindingLoss = true
    }

    private var createWorkspaceAction: (() -> Void)? {
        guard store.canCreateWorkspaceFromCommand(preferredWindowID: nil) else { return nil }
        return {
            _ = store.createWorkspaceFromCommand(preferredWindowID: nil)
        }
    }
}
