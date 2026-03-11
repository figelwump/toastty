import SwiftUI

struct AppWindowSceneHostView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
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
                    terminalRuntimeRegistry: terminalRuntimeRegistry,
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
            if let boundWindowID {
                sceneCoordinator.unregisterPresentedWindow(windowID: boundWindowID)
            }
            boundWindowID = nil
            hasBoundWindow = false
            sceneWindowIDValue = nil
            // Keep the scene alive when the app falls back to the global empty
            // state so the existing window stays on its current display.
            guard store.state.windows.isEmpty == false else { return }
            dismiss()
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

    private var createWorkspaceAction: (() -> Void)? {
        guard store.canCreateWorkspaceFromCommand(preferredWindowID: nil) else { return nil }
        return {
            _ = store.createWorkspaceFromCommand(preferredWindowID: nil)
        }
    }
}
