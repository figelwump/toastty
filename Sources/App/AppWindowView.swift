import AppKit
import CoreState
import SwiftUI

struct AppWindowView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var agentCatalogStore: AgentCatalogStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let agentLaunchService: AgentLaunchService
    let terminalRuntimeContext: TerminalWindowRuntimeContext
    @State private var pendingWorkspaceClose: PendingWorkspaceClose?
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var sidebarDragPreviewWidth: CGFloat?

    private var sidebarVisible: Bool {
        store.window(id: windowID)?.sidebarVisible ?? true
    }

    var body: some View {
        GeometryReader { geometry in
            let resolvedSidebarWidth = resolvedSidebarWidth(availableWidth: geometry.size.width)

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
                        .frame(width: resolvedSidebarWidth)

                        SidebarResizeHandle(
                            onChanged: { translation in
                                updateSidebarDrag(translation: translation, availableWidth: geometry.size.width)
                            },
                            onEnded: { translation in
                                finishSidebarDrag(translation: translation, availableWidth: geometry.size.width)
                            }
                        )
                    }

                    WorkspaceView(
                        windowID: windowID,
                        store: store,
                        agentCatalogStore: agentCatalogStore,
                        terminalProfileStore: terminalProfileStore,
                        terminalRuntimeRegistry: terminalRuntimeRegistry,
                        sessionRuntimeStore: sessionRuntimeStore,
                        agentLaunchService: agentLaunchService,
                        terminalRuntimeContext: terminalRuntimeContext,
                        sidebarVisible: sidebarVisible
                    )
                }
                .animation(.easeInOut(duration: 0.15), value: sidebarVisible)

                // Sidebar toggle button in the title bar area, right of traffic lights
                sidebarToggleButton
            }
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
        .onChange(of: sidebarVisible) { _, isVisible in
            if isVisible == false {
                clearSidebarDragState()
            }
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
        sidebarWidthOverride: Double?,
        hasEverLaunchedAgent: Bool
    ) -> CGFloat {
        CGFloat(
            sidebarWidthOverride
                ?? (hasEverLaunchedAgent
                    ? WindowState.defaultSidebarWidthAfterAgentLaunch
                    : WindowState.defaultSidebarWidthBeforeAgentLaunch)
        )
    }

    static func clampedSidebarWidth(_ width: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let absoluteMinWidth = ToastyTheme.sidebarWidthBeforeAgentLaunch
        let absoluteMaxWidth = CGFloat(WindowState.maximumSidebarWidthOverride)
        let windowScopedMaxWidth = max(
            absoluteMinWidth,
            availableWidth - ToastyTheme.sidebarMinimumWorkspaceWidth - ToastyTheme.sidebarResizeHandleWidth
        )
        let maximumWidth = min(absoluteMaxWidth, windowScopedMaxWidth)
        return min(max(width, absoluteMinWidth), maximumWidth)
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
        .help(
            ToasttyKeyboardShortcuts.toggleSidebar.helpText(
                sidebarVisible ? "Hide Workspaces" : "Show Workspaces"
            )
        )
        .padding(.leading, 76)
        .padding(.top, 5)
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
            sidebarWidthOverride: store.window(id: windowID)?.sidebarWidthOverride,
            hasEverLaunchedAgent: store.hasEverLaunchedAgent
        )
    }

    private func resolvedSidebarWidth(availableWidth: CGFloat) -> CGFloat {
        Self.clampedSidebarWidth(
            sidebarDragPreviewWidth ?? effectiveSidebarWidth,
            availableWidth: availableWidth
        )
    }

    private func updateSidebarDrag(translation: CGFloat, availableWidth: CGFloat) {
        let startWidth = sidebarDragStartWidth ?? resolvedSidebarWidth(availableWidth: availableWidth)
        if sidebarDragStartWidth == nil {
            sidebarDragStartWidth = startWidth
        }

        sidebarDragPreviewWidth = Self.clampedSidebarWidth(
            startWidth + translation,
            availableWidth: availableWidth
        )
    }

    private func finishSidebarDrag(translation: CGFloat, availableWidth: CGFloat) {
        let startWidth = sidebarDragStartWidth ?? resolvedSidebarWidth(availableWidth: availableWidth)
        let finalWidth = sidebarDragPreviewWidth ?? Self.clampedSidebarWidth(
            startWidth + translation,
            availableWidth: availableWidth
        )

        clearSidebarDragState()

        guard abs(finalWidth - startWidth) >= 0.5 else {
            return
        }

        _ = store.send(.setSidebarWidth(windowID: windowID, width: Double(finalWidth)))
    }

    private func clearSidebarDragState() {
        sidebarDragStartWidth = nil
        sidebarDragPreviewWidth = nil
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

private struct SidebarResizeHandle: View {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(backgroundColor)

            Capsule()
                .fill(indicatorColor)
                .frame(width: indicatorWidth, height: indicatorHeight)
        }
        .frame(width: ToastyTheme.sidebarResizeHandleWidth)
        .contentShape(Rectangle())
        .onHover(perform: updateHoverState)
        .onDisappear {
            if isHovering {
                isHovering = false
                NSCursor.pop()
            }
            isDragging = false
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    onChanged(value.translation.width)
                }
                .onEnded { value in
                    isDragging = false
                    onEnded(value.translation.width)
                }
        )
        .accessibilityIdentifier("sidebar.resize-handle")
        .accessibilityLabel("Resize sidebar")
    }

    private var backgroundColor: Color {
        if isDragging {
            return ToastyTheme.sidebarResizeHandleDragBackground
        }
        if isHovering {
            return ToastyTheme.sidebarResizeHandleHoverBackground
        }
        return .clear
    }

    private var indicatorColor: Color {
        if isDragging || isHovering {
            return ToastyTheme.sidebarResizeHandleActiveIndicator
        }
        return ToastyTheme.hairline
    }

    private var indicatorWidth: CGFloat {
        (isDragging || isHovering) ? 2 : 1
    }

    private var indicatorHeight: CGFloat {
        isDragging ? 52 : (isHovering ? 40 : 28)
    }

    private func updateHoverState(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        if hovering {
            isHovering = true
            NSCursor.resizeLeftRight.push()
        } else {
            isHovering = false
            NSCursor.pop()
        }
    }
}
