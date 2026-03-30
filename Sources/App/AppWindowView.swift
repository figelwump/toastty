import CoreState
import SwiftUI

struct AppWindowView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var agentCatalogStore: AgentCatalogStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let profileShortcutRegistry: ProfileShortcutRegistry
    let agentLaunchService: AgentLaunchService
    let openAgentProfilesConfiguration: () -> Void
    let terminalRuntimeContext: TerminalWindowRuntimeContext
    @State private var pendingWorkspaceClose: PendingWorkspaceClose?

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
                        terminalRuntimeRegistry: terminalRuntimeRegistry,
                        sessionRuntimeStore: sessionRuntimeStore,
                        terminalRuntimeContext: terminalRuntimeContext
                    )
                    .frame(width: effectiveSidebarWidth)

                    Rectangle()
                        .fill(ToastyTheme.hairline)
                        .frame(width: 1)
                }

                WorkspaceView(
                    windowID: windowID,
                    store: store,
                    agentCatalogStore: agentCatalogStore,
                    terminalProfileStore: terminalProfileStore,
                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                    sessionRuntimeStore: sessionRuntimeStore,
                    profileShortcutRegistry: profileShortcutRegistry,
                    agentLaunchService: agentLaunchService,
                    openAgentProfilesConfiguration: openAgentProfilesConfiguration,
                    terminalRuntimeContext: terminalRuntimeContext,
                    sidebarVisible: sidebarVisible
                )
            }
            .animation(.easeInOut(duration: 0.15), value: sidebarVisible)

            // Sidebar toggle button in the title bar area, right of traffic lights
            sidebarToggleButton
        }
        .alert(
            "Close this workspace?",
            isPresented: pendingWorkspaceCloseBinding,
            presenting: pendingWorkspaceClose
        ) { closeTarget in
            Button("Cancel", role: .cancel) {
                pendingWorkspaceClose = nil
            }
            Button("Close", role: .destructive) {
                confirmWorkspaceClose(closeTarget)
            }
        } message: { _ in
            Text("Closing this workspace will close all terminals and panels within it.")
        }
        .onAppear {
            scheduleWindowFocusRestore()
        }
        .onChange(of: slotFocusSignature) { _, _ in
            scheduleWindowFocusRestore()
        }
        .onChange(of: store.state.workspacesByID) { _, _ in
            if let pendingWorkspaceClose,
               store.state.workspacesByID[pendingWorkspaceClose.workspaceID] == nil {
                self.pendingWorkspaceClose = nil
            }
        }
        .onChange(of: store.pendingCloseWorkspaceRequest) { _, newValue in
            guard let request = newValue,
                  request.windowID == windowID,
                  store.state.workspacesByID[request.workspaceID] != nil,
                  store.consumePendingWorkspaceCloseRequest(windowID: windowID) != nil else { return }
            pendingWorkspaceClose = PendingWorkspaceClose(
                windowID: request.windowID,
                workspaceID: request.workspaceID
            )
        }
        .focusedSceneValue(\.toasttyCommandWindowID, windowID)
    }

    static func effectiveSidebarWidth(
        hasEverLaunchedAgent: Bool
    ) -> CGFloat {
        hasEverLaunchedAgent ? ToastyTheme.sidebarWidth : ToastyTheme.sidebarWidthBeforeAgentLaunch
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
        .frame(
            width: ToastyTheme.titlebarSidebarToggleButtonSize,
            height: ToastyTheme.titlebarSidebarToggleButtonSize
        )
        .contentShape(Rectangle())
        .help(
            ToasttyKeyboardShortcuts.toggleSidebar.helpText(
                sidebarVisible ? "Hide Workspaces" : "Show Workspaces"
            )
        )
        .padding(.leading, ToastyTheme.titlebarSidebarToggleLeadingPadding)
        .padding(.top, ToastyTheme.titlebarSidebarToggleTopPadding)
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

    private var effectiveSidebarWidth: CGFloat {
        Self.effectiveSidebarWidth(
            hasEverLaunchedAgent: store.hasEverLaunchedAgent
        )
    }

    private func scheduleWindowFocusRestore(avoidStealingKeyboardFocus: Bool = true) {
        guard let workspaceID = store.selectedWorkspace(in: windowID)?.id else { return }
        terminalRuntimeContext.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
        )
    }

    private var pendingWorkspaceCloseBinding: Binding<Bool> {
        Binding(
            get: { pendingWorkspaceClose != nil },
            set: { isPresented in
                if !isPresented {
                    pendingWorkspaceClose = nil
                }
            }
        )
    }

    private func confirmWorkspaceClose(_ closeTarget: PendingWorkspaceClose) {
        pendingWorkspaceClose = nil
        _ = store.confirmWorkspaceClose(
            windowID: closeTarget.windowID,
            workspaceID: closeTarget.workspaceID
        )
    }
}

private struct WindowSlotFocusSignature: Equatable {
    let windowID: UUID
    let workspaceID: UUID?
    let focusedPanelID: UUID?
}

private struct PendingWorkspaceClose: Identifiable {
    let windowID: UUID
    let workspaceID: UUID

    var id: UUID { workspaceID }
}
