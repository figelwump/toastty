import AppKit
import CoreState
import SwiftUI

struct AppWindowSceneView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var agentCatalogStore: AgentCatalogStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let profileShortcutRegistry: ProfileShortcutRegistry
    let agentLaunchService: AgentLaunchService
    let openAgentProfilesConfigurationResult: @MainActor () -> Result<Void, AgentGetStartedActionError>
    let openKeyboardShortcutsReferenceResult: @MainActor () -> Result<Void, AgentGetStartedActionError>
    let onWindowCloseInitiated: @MainActor () -> Void
    let disableAnimations: Bool

    @State private var fontHUDValue: FontHUDValue?
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

    private var effectiveWindowFontPoints: Double? {
        guard windowState != nil else { return nil }
        return store.state.effectiveTerminalFontPoints(for: windowID)
    }

    private var effectiveWindowMarkdownTextScale: Double? {
        guard windowState != nil else { return nil }
        return store.state.effectiveMarkdownTextScale(for: windowID)
    }

    private var effectiveWindowTextMetrics: WindowTextMetrics? {
        guard let terminalPoints = effectiveWindowFontPoints,
              let markdownTextScale = effectiveWindowMarkdownTextScale else {
            return nil
        }
        return WindowTextMetrics(
            terminalPoints: terminalPoints,
            markdownTextScale: markdownTextScale
        )
    }

    private var showsEmptyState: Bool {
        guard let windowState else { return true }
        return windowState.workspaceIDs.isEmpty
    }

    private var shouldConfirmWindowClose: Bool {
        guard let windowState else { return false }
        guard windowState.workspaceIDs.isEmpty == false else { return false }
        return !AutomationConfig.shouldBypassInteractiveConfirmation(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    var body: some View {
        Group {
            if showsEmptyState == false {
                AppWindowView(
                    windowID: windowID,
                    store: store,
                    agentCatalogStore: agentCatalogStore,
                    terminalProfileStore: terminalProfileStore,
                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                    webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                    sessionRuntimeStore: sessionRuntimeStore,
                    profileShortcutRegistry: profileShortcutRegistry,
                    agentLaunchService: agentLaunchService,
                    openAgentProfilesConfigurationResult: openAgentProfilesConfigurationResult,
                    openKeyboardShortcutsReferenceResult: openKeyboardShortcutsReferenceResult,
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
            if let fontHUDValue {
                FontHUD(value: fontHUDValue)
                    .padding(.top, ToastyTheme.fontHUDTopPadding)
            }
        }
        .background {
            AppWindowSceneObserver(
                windowID: windowID,
                desiredFrame: windowState?.frame,
                windowTitle: store.selectedWorkspace(in: windowID)?.title,
                shouldConfirmWindowClose: shouldConfirmWindowClose,
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
        .onChange(of: effectiveWindowTextMetrics) { previousMetrics, nextMetrics in
            guard let previousMetrics, let nextMetrics else { return }

            if abs(nextMetrics.terminalPoints - previousMetrics.terminalPoints) >= AppState.terminalFontComparisonEpsilon {
                showFontHUD(.terminal(points: nextMetrics.terminalPoints))
                return
            }

            if abs(nextMetrics.markdownTextScale - previousMetrics.markdownTextScale) >= AppState.markdownTextScaleComparisonEpsilon {
                showFontHUD(.markdown(scale: nextMetrics.markdownTextScale))
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

    private func showFontHUD(_ value: FontHUDValue) {
        fontHUDValue = value
        hideFontHUDTask?.cancel()
        hideFontHUDTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.2))
            } catch {
                return
            }
            fontHUDValue = nil
            hideFontHUDTask = nil
        }
    }

    private var createWorkspaceAction: (() -> Void)? {
        guard store.canCreateWorkspaceFromCommand(preferredWindowID: windowID) else { return nil }
        return {
            _ = store.createWorkspaceFromCommand(preferredWindowID: windowID)
        }
    }
}

private struct WindowTextMetrics: Equatable {
    let terminalPoints: Double
    let markdownTextScale: Double
}

private enum FontHUDValue: Equatable {
    case terminal(points: Double)
    case markdown(scale: Double)
}

private struct FontHUD: View {
    let value: FontHUDValue

    var body: some View {
        Text(title)
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

    private var title: String {
        switch value {
        case .terminal(let points):
            return "Terminal Font \(Int(points.rounded())) pt"
        case .markdown(let scale):
            return "Markdown Text \(Int((scale * 100).rounded()))%"
        }
    }
}
