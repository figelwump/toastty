import SwiftUI

struct AppWindowView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    let terminalRuntimeContext: TerminalWindowRuntimeContext

    private var sidebarVisible: Bool {
        store.window(id: windowID)?.sidebarVisible ?? true
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if sidebarVisible {
                    SidebarView(
                        windowID: windowID,
                        store: store,
                        terminalRuntimeContext: terminalRuntimeContext
                    )
                        .frame(width: ToastyTheme.sidebarWidth)

                    Rectangle()
                        .fill(ToastyTheme.hairline)
                        .frame(width: 1)
                }

                WorkspaceView(
                    windowID: windowID,
                    store: store,
                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                    terminalRuntimeContext: terminalRuntimeContext,
                    sidebarVisible: sidebarVisible
                )
            }
            .animation(.easeInOut(duration: 0.15), value: sidebarVisible)

            // Sidebar toggle button in the title bar area, right of traffic lights
            sidebarToggleButton
        }
        .onAppear {
            scheduleWindowFocusRestore()
        }
        .onChange(of: slotFocusSignature) { _, _ in
            scheduleWindowFocusRestore()
        }
        .focusedSceneValue(\.toasttyCommandWindowID, windowID)
    }

    private var sidebarToggleButton: some View {
        Button {
            store.send(.toggleSidebar(windowID: windowID))
        } label: {
            SidebarToggleIconView(
                color: sidebarVisible ? ToastyTheme.inactiveText : ToastyTheme.accent,
                sidebarVisible: sidebarVisible
            )
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .padding(.leading, 76)
        .padding(.top, 7)
        .accessibilityIdentifier("titlebar.toggle.sidebar")
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
