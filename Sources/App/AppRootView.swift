import AppKit
import SwiftUI

struct AppRootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let automationLifecycle: AutomationLifecycle?
    let automationStartupError: String?
    let disableAnimations: Bool
    @State private var fontHUDPoints: Double?
    @State private var hideFontHUDTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                store: store,
                terminalRuntimeContext: selectedWindowRuntimeContext
            )
                .frame(width: ToastyTheme.sidebarWidth)

            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(width: 1)

            WorkspaceView(
                store: store,
                terminalRuntimeContext: selectedWindowRuntimeContext
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ToastyTheme.chromeBackground)
        .foregroundStyle(ToastyTheme.primaryText)
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let fontHUDPoints {
                FontHUD(points: fontHUDPoints)
                    .padding(.top, 12)
            }
        }
        .task {
            automationLifecycle?.markReady(runtimeError: automationStartupError)
            scheduleSelectedWorkspaceFocusRestore()
        }
        .onChange(of: selectedSlotFocusSignature) { _, _ in
            scheduleSelectedWorkspaceFocusRestore()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            scheduleSelectedWorkspaceFocusRestore()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            terminalRuntimeRegistry.synchronizeGhosttySurfaceFocusFromApplicationState()
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
        .onDisappear {
            hideFontHUDTask?.cancel()
            hideFontHUDTask = nil
        }
        .transaction { transaction in
            if disableAnimations {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }

    private var selectedSlotFocusSignature: SelectedSlotFocusSignature? {
        guard let selectedWindow = store.selectedWindow else { return nil }
        return SelectedSlotFocusSignature(
            windowID: selectedWindow.id,
            workspaceID: selectedWindow.selectedWorkspaceID,
            focusedPanelID: store.selectedWorkspace?.focusedPanelID
        )
    }

    private var selectedWindowRuntimeContext: TerminalWindowRuntimeContext? {
        guard let windowID = store.selectedWindow?.id else { return nil }
        return TerminalWindowRuntimeContext(
            windowID: windowID,
            runtimeRegistry: terminalRuntimeRegistry
        )
    }

    private func scheduleSelectedWorkspaceFocusRestore(avoidStealingKeyboardFocus: Bool = true) {
        guard let workspaceID = store.selectedWorkspace?.id,
              let terminalRuntimeContext = selectedWindowRuntimeContext else {
            return
        }
        terminalRuntimeContext.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
        )
    }
}

private struct SelectedSlotFocusSignature: Equatable {
    let windowID: UUID
    let workspaceID: UUID?
    let focusedPanelID: UUID?
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
