import SwiftUI

struct AppWindowView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    let terminalRuntimeContext: TerminalWindowRuntimeContext

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                windowID: windowID,
                store: store,
                terminalRuntimeContext: terminalRuntimeContext
            )
                .frame(width: ToastyTheme.sidebarWidth)

            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(width: 1)

            WorkspaceView(
                windowID: windowID,
                store: store,
                terminalProfileStore: terminalProfileStore,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                terminalRuntimeContext: terminalRuntimeContext
            )
        }
        .onAppear {
            scheduleWindowFocusRestore()
        }
        .onChange(of: slotFocusSignature) { _, _ in
            scheduleWindowFocusRestore()
        }
        .focusedSceneValue(\.toasttyCommandWindowID, windowID)
    }

    private var slotFocusSignature: WindowSlotFocusSignature? {
        guard store.window(id: windowID) != nil else { return nil }
        return WindowSlotFocusSignature(
            windowID: windowID,
            workspaceID: store.selectedWorkspaceID(in: windowID),
            focusedPanelID: store.selectedWorkspace(in: windowID)?.focusedPanelID
        )
    }

    private func scheduleWindowFocusRestore(avoidStealingKeyboardFocus: Bool = true) {
        guard let workspaceID = store.selectedWorkspace(in: windowID)?.id else { return }
        terminalRuntimeContext.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
        )
    }
}

private struct WindowSlotFocusSignature: Equatable {
    let windowID: UUID
    let workspaceID: UUID?
    let focusedPanelID: UUID?
}
