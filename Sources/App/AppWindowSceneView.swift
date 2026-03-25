import AppKit
import CoreState
import SwiftUI

struct AppWindowSceneView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var agentCatalogStore: AgentCatalogStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let profileShortcutRegistry: ProfileShortcutRegistry
    let agentLaunchService: AgentLaunchService
    let openAgentProfilesConfiguration: () -> Void
    let onWindowCloseInitiated: @MainActor () -> Void
    let disableAnimations: Bool

    @State private var fontHUDPoints: Double?
    @State private var hideFontHUDTask: Task<Void, Never>?

    private var terminalRuntimeContext: TerminalWindowRuntimeContext {
        TerminalWindowRuntimeContext(
            windowID: windowID,
            runtimeRegistry: terminalRuntimeRegistry
        )
    }

    private var windowState: WindowState? {
        store.window(id: windowID)
    }

    var body: some View {
        Group {
            if windowState != nil {
                AppWindowView(
                    windowID: windowID,
                    store: store,
                    agentCatalogStore: agentCatalogStore,
                    terminalProfileStore: terminalProfileStore,
                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                    sessionRuntimeStore: sessionRuntimeStore,
                    profileShortcutRegistry: profileShortcutRegistry,
                    agentLaunchService: agentLaunchService,
                    openAgentProfilesConfiguration: openAgentProfilesConfiguration,
                    terminalRuntimeContext: terminalRuntimeContext
                )
            } else {
                EmptyStateView(onCreateWorkspace: createWorkspaceAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .background(ToastyTheme.chromeBackground)
        .foregroundStyle(ToastyTheme.primaryText)
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let fontHUDPoints {
                FontHUD(points: fontHUDPoints)
                    .padding(.top, ToastyTheme.fontHUDTopPadding)
            }
        }
        .background {
            AppWindowSceneObserver(
                windowID: windowID,
                desiredFrame: windowState?.frame,
                windowTitle: store.selectedWorkspace(in: windowID)?.title,
                onWindowDidBecomeKey: handleWindowDidBecomeKey,
                onWindowFrameChange: handleWindowFrameChange,
                onWindowCloseInitiated: onWindowCloseInitiated,
                onWindowWillClose: handleWindowWillClose
            )
        }
        .onDisappear {
            hideFontHUDTask?.cancel()
            hideFontHUDTask = nil
        }
        .onChange(of: store.state.globalTerminalFontPoints) { _, nextPoints in
            fontHUDPoints = nextPoints
            hideFontHUDTask?.cancel()
            hideFontHUDTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(1.2))
                } catch {
                    return
                }
                fontHUDPoints = nil
                hideFontHUDTask = nil
            }
        }
        .transaction { transaction in
            if disableAnimations {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }

    private func handleWindowDidBecomeKey() {
        guard windowState != nil else { return }
        _ = store.send(.selectWindow(windowID: windowID))
        scheduleWindowFocusRestore()
    }

    private func handleWindowFrameChange(_ frame: CGRectCodable) {
        _ = store.send(.updateWindowFrame(windowID: windowID, frame: frame))
    }

    private func handleWindowWillClose() {
        guard windowState != nil else { return }
        _ = store.send(.closeWindow(windowID: windowID))
    }

    private func scheduleWindowFocusRestore(avoidStealingKeyboardFocus: Bool = true) {
        guard let workspaceID = store.selectedWorkspace(in: windowID)?.id else { return }
        terminalRuntimeContext.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
        )
    }

    private var createWorkspaceAction: (() -> Void)? {
        guard store.canCreateWorkspaceFromCommand(preferredWindowID: windowID) else { return nil }
        return {
            _ = store.createWorkspaceFromCommand(preferredWindowID: windowID)
        }
    }
}

private struct FontHUD: View {
    let points: Double

    var body: some View {
        Text("Terminal Font \(Int(points))")
            .font(.headline.monospaced())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(ToastyTheme.primaryText)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(ToastyTheme.hairline, lineWidth: 1)
            )
    }
}
