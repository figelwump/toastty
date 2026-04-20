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
    let focusedPanelCommandController: FocusedPanelCommandController
    let agentLaunchService: AgentLaunchService
    let openAgentProfilesConfigurationResult: @MainActor () -> Result<Void, AgentGetStartedActionError>
    let openKeyboardShortcutsReferenceResult: @MainActor () -> Result<Void, AgentGetStartedActionError>
    let toggleCommandPalette: @MainActor (UUID) -> Void
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

    private var focusedScaleHUDMeasurement: FocusedScaleHUDMeasurement? {
        guard windowState != nil,
              let target = store.focusedScaleCommandTarget(preferredWindowID: windowID) else {
            return nil
        }

        switch target {
        case .terminal(let windowID):
            guard let terminalPoints = effectiveWindowFontPoints else { return nil }
            return .terminal(windowID: windowID, points: terminalPoints)

        case .markdown(let windowID):
            guard let markdownTextScale = effectiveWindowMarkdownTextScale else { return nil }
            return .markdown(windowID: windowID, scale: markdownTextScale)

        case .browser(_, let panelID):
            guard let selection = store.state.workspaceSelection(containingPanelID: panelID),
                  let panelState = selection.workspace.panels[panelID],
                  case .web(let webState) = panelState else {
                return nil
            }
            return .browser(panelID: panelID, zoom: webState.effectiveBrowserPageZoom)
        }
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
                    focusedPanelCommandController: focusedPanelCommandController,
                    agentLaunchService: agentLaunchService,
                    openAgentProfilesConfigurationResult: openAgentProfilesConfigurationResult,
                    openKeyboardShortcutsReferenceResult: openKeyboardShortcutsReferenceResult,
                    toggleCommandPalette: toggleCommandPalette,
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
        .onChange(of: focusedScaleHUDMeasurement) { previousMeasurement, nextMeasurement in
            guard let previousMeasurement, let nextMeasurement else { return }

            switch (previousMeasurement, nextMeasurement) {
            case let (.terminal(previousWindowID, previousPoints), .terminal(nextWindowID, nextPoints)):
                guard previousWindowID == nextWindowID,
                      abs(nextPoints - previousPoints) >= AppState.terminalFontComparisonEpsilon else {
                    return
                }
                showFontHUD(.terminal(points: nextPoints))

            case let (.markdown(previousWindowID, previousScale), .markdown(nextWindowID, nextScale)):
                guard previousWindowID == nextWindowID,
                      abs(nextScale - previousScale) >= AppState.markdownTextScaleComparisonEpsilon else {
                    return
                }
                showFontHUD(.markdown(scale: nextScale))

            case let (.browser(previousPanelID, previousZoom), .browser(nextPanelID, nextZoom)):
                guard previousPanelID == nextPanelID,
                      abs(nextZoom - previousZoom) >= WebPanelState.browserPageZoomComparisonEpsilon else {
                    return
                }
                showFontHUD(.browser(zoom: nextZoom))

            default:
                return
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

private enum FocusedScaleHUDMeasurement: Equatable {
    case terminal(windowID: UUID, points: Double)
    case markdown(windowID: UUID, scale: Double)
    case browser(panelID: UUID, zoom: Double)
}

private enum FontHUDValue: Equatable {
    case terminal(points: Double)
    case markdown(scale: Double)
    case browser(zoom: Double)
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
        case .browser(let zoom):
            return "Zoom \(Int((zoom * 100).rounded()))%"
        }
    }
}
