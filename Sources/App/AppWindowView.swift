import AppKit
import CoreState
import SwiftUI

struct AppWindowView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var agentCatalogStore: AgentCatalogStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    let webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let profileShortcutRegistry: ProfileShortcutRegistry
    let focusedPanelCommandController: FocusedPanelCommandController
    let agentLaunchService: AgentLaunchService
    let openAgentProfilesConfigurationResult: @MainActor () -> Result<Void, AgentGetStartedActionError>
    let openKeyboardShortcutsReferenceResult: @MainActor () -> Result<Void, AgentGetStartedActionError>
    let toggleCommandPalette: @MainActor (UUID) -> Void
    let presentCommandPalette: @MainActor (UUID, String?) -> Void
    let terminalRuntimeContext: TerminalWindowRuntimeContext
    @State private var pendingWorkspaceClose: PendingWorkspaceClose?
    @State private var showsAgentGetStartedSheet = false

    static let sidebarResizeHandleHitWidth: CGFloat = 10
    static let sidebarDividerWidth: CGFloat = 1

    private var sidebarVisible: Bool {
        store.window(id: windowID)?.sidebarVisible ?? true
    }

    private var sidebarToggleHasUnreadBadge: Bool {
        Self.sidebarToggleShowsUnreadBadge(
            sidebarVisible: sidebarVisible,
            hasUnreadNotifications: store.state.windowHasAnyUnreadNotifications(windowID: windowID)
        )
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
                        .frame(width: Self.sidebarDividerWidth)
                }

                WorkspaceView(
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
                    showAgentGetStartedFlow: presentAgentGetStartedFlow,
                    toggleCommandPalette: toggleCommandPalette,
                    presentCommandPalette: presentCommandPalette,
                    terminalRuntimeContext: terminalRuntimeContext,
                    sidebarVisible: sidebarVisible
                )
            }
            .animation(.easeInOut(duration: 0.15), value: sidebarVisible)
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    if sidebarVisible {
                        SidebarResizeLayer(
                            windowID: windowID,
                            sidebarWidth: effectiveSidebarWidth,
                            defaultSidebarWidth: defaultSidebarWidth,
                            height: geometry.size.height,
                            store: store
                        )
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: .topLeading
                        )
                    }
                }
            }

            // Sidebar toggle button in the title bar area, right of traffic lights
            sidebarToggleButton
        }
        .alert(
            "Close this workspace?",
            isPresented: pendingWorkspaceCloseBinding,
            presenting: pendingWorkspaceClose
        ) { closeTarget in
            if closeTarget.allowsDestructiveConfirmation {
                Button("Cancel", role: .cancel) {
                    pendingWorkspaceClose = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Close") {
                    confirmWorkspaceClose(closeTarget)
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("OK") {
                    pendingWorkspaceClose = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        } message: { closeTarget in
            Text(closeTarget.confirmationMessage)
        }
        .sheet(isPresented: $showsAgentGetStartedSheet) {
            agentGetStartedSheet
        }
        .onAppear {
            scheduleWindowFocusRestore()
        }
        .onChange(of: slotFocusSignature) { _, _ in
            handleSlotFocusSignatureChange()
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
            let closeConfirmationSummary: LocalDocumentCloseConfirmationSummary
            if let workspace = store.state.workspacesByID[request.workspaceID] {
                closeConfirmationSummary = webPanelRuntimeRegistry.localDocumentCloseConfirmationSummary(
                    panelIDs: workspace.allPanelsByID.keys
                )
            } else {
                closeConfirmationSummary = .none
            }
            pendingWorkspaceClose = PendingWorkspaceClose(
                windowID: request.windowID,
                workspaceID: request.workspaceID,
                unsavedLocalDocumentDraftCount: closeConfirmationSummary.dirtyDraftCount,
                firstUnsavedLocalDocumentDisplayName: closeConfirmationSummary.firstDirtyDraftDisplayName,
                localDocumentSaveInProgressCount: closeConfirmationSummary.saveInProgressCount,
                firstLocalDocumentSaveInProgressDisplayName: closeConfirmationSummary.firstSaveInProgressDisplayName
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .toasttyShowAgentGetStartedFlow)) { notification in
            guard Self.shouldPresentAgentGetStartedFlow(
                windowID: windowID,
                notificationObject: notification.object
            ) else { return }
            presentAgentGetStartedFlow()
        }
        .focusedSceneValue(\.toasttyCommandWindowID, windowID)
    }

    static func effectiveSidebarWidth(
        hasEverLaunchedAgent: Bool
    ) -> CGFloat {
        effectiveSidebarWidth(
            hasEverLaunchedAgent: hasEverLaunchedAgent,
            sidebarWidthPointsOverride: nil
        )
    }

    static func effectiveSidebarWidth(
        hasEverLaunchedAgent: Bool,
        sidebarWidthPointsOverride: Double?
    ) -> CGFloat {
        if let override = WindowState.normalizedSidebarWidthOverride(sidebarWidthPointsOverride) {
            return CGFloat(override)
        }

        return defaultSidebarWidth(hasEverLaunchedAgent: hasEverLaunchedAgent)
    }

    static func defaultSidebarWidth(hasEverLaunchedAgent: Bool) -> CGFloat {
        hasEverLaunchedAgent ? ToastyTheme.sidebarWidth : ToastyTheme.sidebarWidthBeforeAgentLaunch
    }

    static func sidebarResizeHandleFrame(
        sidebarWidth: CGFloat,
        height: CGFloat
    ) -> CGRect {
        let dividerCenterX = sidebarWidth + (Self.sidebarDividerWidth / 2)
        return CGRect(
            x: dividerCenterX - (Self.sidebarResizeHandleHitWidth / 2),
            y: 0,
            width: Self.sidebarResizeHandleHitWidth,
            height: max(0, height)
        )
    }

    static func sidebarToggleShowsUnreadBadge(
        sidebarVisible: Bool,
        hasUnreadNotifications: Bool
    ) -> Bool {
        hasUnreadNotifications && !sidebarVisible
    }

    static func sidebarToggleAccessibilityLabel(sidebarVisible: Bool) -> String {
        sidebarVisible ? "Hide Workspaces" : "Show Workspaces"
    }

    static func sidebarToggleAccessibilityValue(hasUnreadBadge: Bool) -> String {
        hasUnreadBadge ? "Unread notifications" : ""
    }

    static func shouldPresentAgentGetStartedFlow(windowID: UUID, notificationObject: Any?) -> Bool {
        guard let targetWindowID = notificationObject as? UUID else {
            return false
        }
        return targetWindowID == windowID
    }

    private var sidebarToggleButton: some View {
        Button {
            store.send(.toggleSidebar(windowID: windowID))
        } label: {
            SidebarToggleIconView(
                color: sidebarVisible ? ToastyTheme.accent : ToastyTheme.inactiveText,
                sidebarVisible: sidebarVisible,
                hasUnread: sidebarToggleHasUnreadBadge
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
                Self.sidebarToggleAccessibilityLabel(sidebarVisible: sidebarVisible)
            )
        )
        .padding(.leading, ToastyTheme.titlebarSidebarToggleLeadingPadding)
        .padding(.top, ToastyTheme.titlebarSidebarToggleTopPadding)
        .accessibilityLabel(Self.sidebarToggleAccessibilityLabel(sidebarVisible: sidebarVisible))
        .accessibilityValue(Self.sidebarToggleAccessibilityValue(hasUnreadBadge: sidebarToggleHasUnreadBadge))
        .accessibilityIdentifier("titlebar.toggle.sidebar")
    }

    private var agentGetStartedSheet: some View {
        AgentGetStartedSheet(
            openAgentProfilesConfiguration: openAgentProfilesConfigurationResult,
            openKeyboardShortcutsReference: openKeyboardShortcutsReferenceResult,
            resolveShellIntegrationPreferredShellPath: resolveShellIntegrationPreferredShellPath
        )
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
            hasEverLaunchedAgent: store.hasEverLaunchedAgent,
            sidebarWidthPointsOverride: store.window(id: windowID)?.sidebarWidthPointsOverride
        )
    }

    private var defaultSidebarWidth: CGFloat {
        Self.defaultSidebarWidth(hasEverLaunchedAgent: store.hasEverLaunchedAgent)
    }

    @MainActor
    private func resolveShellIntegrationPreferredShellPath() -> String? {
        terminalRuntimeRegistry.resolveShellIntegrationShellPath(
            preferredWindowID: windowID
        )
    }

    @MainActor
    private func presentAgentGetStartedFlow() {
        showsAgentGetStartedSheet = true
    }

    private func scheduleWindowFocusRestore(avoidStealingKeyboardFocus: Bool = true) {
        guard let workspaceID = store.selectedWorkspace(in: windowID)?.id else { return }
        terminalRuntimeContext.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
        )
    }

    private func handleSlotFocusSignatureChange() {
        DispatchQueue.main.async {
            let activePanelID = slotFocusSignature?.focusedPanelID
            let releasedBackgroundSearchFieldFocus = terminalRuntimeContext.releaseInactiveSearchFieldFocus(
                activePanelID: activePanelID
            )
            scheduleWindowFocusRestore(
                avoidStealingKeyboardFocus: releasedBackgroundSearchFieldFocus == false
            )
        }
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

private struct SidebarResizeLayer: View {
    let windowID: UUID
    let sidebarWidth: CGFloat
    let defaultSidebarWidth: CGFloat
    let height: CGFloat
    @ObservedObject var store: AppStore

    @State private var resizeStartWidth: Double?

    var body: some View {
        BoundaryInteractionOverlay(descriptors: [boundaryDescriptor])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDisappear {
                resizeStartWidth = nil
            }
    }

    private var boundaryDescriptor: BoundaryInteractionDescriptor {
        BoundaryInteractionDescriptor(
            id: boundaryID,
            hitFrame: AppWindowView.sidebarResizeHandleFrame(
                sidebarWidth: sidebarWidth,
                height: height
            ),
            visualFrame: CGRect(
                x: sidebarWidth,
                y: 0,
                width: AppWindowView.sidebarDividerWidth,
                height: height
            ),
            axis: .vertical,
            cursor: .resizeLeftRight,
            accessibilityLabel: "Resize Sidebar",
            accessibilityIdentifier: "sidebar.resize",
            metadata: [
                "windowID": windowID.uuidString,
                "sidebarWidth": String(format: "%.1f", sidebarWidth),
            ],
            onBegan: { _ in
                resizeStartWidth = Double(sidebarWidth)
            },
            onChanged: { value in
                guard let startingWidth = resizeStartWidth else { return }
                let nextWidth = startingWidth + Double(value.translation.width)
                _ = store.send(
                    .setSidebarWidth(
                        windowID: windowID,
                        width: nextWidth,
                        defaultWidth: Double(defaultSidebarWidth)
                    )
                )
            },
            onEnded: { _ in
                resizeStartWidth = nil
            }
        )
    }

    private var boundaryID: String {
        "sidebar.resize.\(windowID.uuidString)"
    }
}

private struct PendingWorkspaceClose: Identifiable {
    let windowID: UUID
    let workspaceID: UUID
    let unsavedLocalDocumentDraftCount: Int
    let firstUnsavedLocalDocumentDisplayName: String?
    let localDocumentSaveInProgressCount: Int
    let firstLocalDocumentSaveInProgressDisplayName: String?

    var id: UUID { workspaceID }

    var allowsDestructiveConfirmation: Bool {
        localDocumentSaveInProgressCount == 0
    }

    var confirmationMessage: String {
        var paragraphs: [String] = []

        if localDocumentSaveInProgressCount == 1,
           let firstLocalDocumentSaveInProgressDisplayName {
            paragraphs.append(
                "\"\(firstLocalDocumentSaveInProgressDisplayName)\" is still saving. Wait for the save to finish before closing this workspace."
            )
        } else if localDocumentSaveInProgressCount > 1 {
            paragraphs.append(
                "This workspace still has document saves in progress. Wait for them to finish before closing the workspace."
            )
        }

        if unsavedLocalDocumentDraftCount == 1,
           let firstUnsavedLocalDocumentDisplayName {
            paragraphs.append(
                "\"\(firstUnsavedLocalDocumentDisplayName)\" has unsaved document changes. Closing the workspace will discard them."
            )
        } else if unsavedLocalDocumentDraftCount > 1 {
            paragraphs.append("This workspace has unsaved document changes. Closing the workspace will discard them.")
        }

        paragraphs.append("Closing this workspace will close all terminals and panels within it.")
        return paragraphs.joined(separator: "\n\n")
    }
}
