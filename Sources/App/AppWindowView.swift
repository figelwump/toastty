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
    let annotationStyleStore: AnnotationStyleStore
    let profileShortcutRegistry: ProfileShortcutRegistry
    let focusedPanelCommandController: FocusedPanelCommandController
    let agentLaunchService: AgentLaunchService
    let openAgentProfilesConfigurationResult: @MainActor () -> Result<Void, ToasttyMenuActionError>
    let openKeyboardShortcutsReferenceResult: @MainActor () -> Result<Void, ToasttyMenuActionError>
    let toggleCommandPalette: @MainActor (UUID) -> Void
    let presentCommandPalette: @MainActor (UUID, String?) -> Void
    let terminalRuntimeContext: TerminalWindowRuntimeContext
    @State private var pendingWorkspaceClose: PendingWorkspaceClose?
    @State private var showsSkillsManagementSheet = false
    @State private var skillsProvisionedNotice: ManagedAgentSkillsProvisionedNotice?
    @State private var queuedSkillsProvisionedNotices: [ManagedAgentSkillsProvisionedNotice] = []
    @State private var codexSkillsUnavailableNotice: ManagedCodexSkillsUnavailableNotice?
    @State private var lastCodexSkillsUnavailableReasonCode: String?
    @State private var appIsActive = true
    @Environment(\.openWindow) private var openWindow

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
                        annotationStyleStore: annotationStyleStore,
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
                    terminalLiveTitleStore: terminalRuntimeRegistry.terminalLiveTitleStore,
                    webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                    sessionRuntimeStore: sessionRuntimeStore,
                    profileShortcutRegistry: profileShortcutRegistry,
                    focusedPanelCommandController: focusedPanelCommandController,
                    agentLaunchService: agentLaunchService,
                    openGettingStartedPanel: {
                        guard let workspaceID = store.selectedWorkspace(in: windowID)?.id else { return }
                        _ = store.openGettingStartedPanel(workspaceID: workspaceID)
                    },
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
                            appIsActive: appIsActive,
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

            if let skillsProvisionedNotice {
                ManagedAgentSkillsProvisionedBanner(
                    notice: skillsProvisionedNotice,
                    manage: {
                        advanceSkillsProvisionedNotice()
                        showsSkillsManagementSheet = true
                    },
                    dismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            advanceSkillsProvisionedNotice()
                        }
                    }
                )
                .frame(maxWidth: 680)
                .padding(.top, 42)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(20)
            }

            if let codexSkillsUnavailableNotice {
                ManagedCodexSkillsUnavailableBanner(
                    notice: codexSkillsUnavailableNotice,
                    manage: {
                        self.codexSkillsUnavailableNotice = nil
                        showsSkillsManagementSheet = true
                    },
                    dismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            self.codexSkillsUnavailableNotice = nil
                        }
                    }
                )
                .frame(maxWidth: 680)
                .padding(.top, 42)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(21)
            }
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
        .sheet(isPresented: $showsSkillsManagementSheet) {
            ToasttySkillsManagementSheet(
                sessionRuntimeStore: sessionRuntimeStore,
                codexSkillsManager: agentLaunchService.codexSkillsManager,
                claudeSkillsBundleManager: agentLaunchService.claudeSkillsBundleManager,
                userSkillCatalog: agentLaunchService.userSkillCatalog,
                processPathProvider: agentLaunchService.codexProcessPathSnapshotProvider,
                processPathRefreshProvider: agentLaunchService.codexProcessPathRefresher
            )
        }
        .onAppear {
            appIsActive = NSApplication.shared.isActive
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
                source: request.source,
                unsavedLocalDocumentDraftCount: closeConfirmationSummary.dirtyDraftCount,
                firstUnsavedLocalDocumentDisplayName: closeConfirmationSummary.firstDirtyDraftDisplayName,
                localDocumentSaveInProgressCount: closeConfirmationSummary.saveInProgressCount,
                firstLocalDocumentSaveInProgressDisplayName: closeConfirmationSummary.firstSaveInProgressDisplayName
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .toasttyShowAgentGetStartedFlow)) { notification in
            guard let request = notification.object as? GettingStartedPanelRequest else { return }

            switch request {
            case .open(let targetWindowID, let anchor):
                guard targetWindowID == windowID,
                      let workspaceID = store.selectedWorkspace(in: windowID)?.id else {
                    return
                }
                _ = store.openGettingStartedPanel(workspaceID: workspaceID, anchor: anchor)

            case .performNativeAction(let panelID, let action):
                guard store.state.workspaceSelection(containingPanelID: panelID)?.windowID == windowID else {
                    return
                }
                performGettingStartedPanelNativeAction(action)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toasttyShowSkillsManagement)) { notification in
            guard notification.object as? UUID == windowID else { return }
            showsSkillsManagementSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toasttyOpenRemoteAccess)) { notification in
            guard notification.object as? UUID == windowID else { return }
            openWindow(id: RemoteAccessWindowSceneID.value)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toasttyManagedAgentSkillsProvisioned)) { notification in
            if let notice = notification.object as? ManagedAgentSkillsProvisionedNotice,
               notice.windowID == windowID,
               notice.agent == .codex {
                codexSkillsUnavailableNotice = nil
                lastCodexSkillsUnavailableReasonCode = nil
            }
            guard let notice = ManagedAgentSkillsProvisionedNoticeStore.claim(
                for: windowID,
                notificationObject: notification.object
            ) else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                if skillsProvisionedNotice == nil {
                    skillsProvisionedNotice = notice
                } else if queuedSkillsProvisionedNotices.contains(where: { $0.agent == notice.agent }) == false {
                    queuedSkillsProvisionedNotices.append(notice)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toasttyManagedCodexSkillsUnavailable)) { notification in
            guard let notice = notification.object as? ManagedCodexSkillsUnavailableNotice,
                  notice.windowID == windowID,
                  notice.reasonCode != lastCodexSkillsUnavailableReasonCode else { return }
            lastCodexSkillsUnavailableReasonCode = notice.reasonCode
            withAnimation(.easeOut(duration: 0.15)) {
                codexSkillsUnavailableNotice = notice
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appIsActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appIsActive = false
        }
        .focusedSceneValue(\.toasttyCommandWindowID, windowID)
    }

    private func advanceSkillsProvisionedNotice() {
        if queuedSkillsProvisionedNotices.isEmpty {
            skillsProvisionedNotice = nil
        } else {
            skillsProvisionedNotice = queuedSkillsProvisionedNotices.removeFirst()
        }
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
    private func performGettingStartedPanelNativeAction(_ action: GettingStartedPanelNativeAction) {
        let result: Result<Void, ToasttyMenuActionError>
        switch action {
        case .openAgentProfiles:
            result = openAgentProfilesConfigurationResult()
        case .openSkillsManagement:
            showsSkillsManagementSheet = true
            result = .success(())
        case .openShortcutReference:
            result = openKeyboardShortcutsReferenceResult()
        }

        if case .failure(let error) = result {
            ToasttyLog.warning(
                "Getting Started page action failed",
                category: .state,
                metadata: ["action": action.rawValue, "error": error.localizedDescription]
            )
        }
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
            workspaceID: closeTarget.workspaceID,
            source: closeTarget.source
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
    let appIsActive: Bool
    @ObservedObject var store: AppStore

    @State private var resizeStartWidth: Double?
    @State private var hovered = false
    @State private var dragging = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            BoundaryResizeHandleVisual(
                highlighted: highlighted,
                appIsActive: appIsActive,
                width: AppWindowView.sidebarDividerWidth
            )
            .frame(
                width: AppWindowView.sidebarResizeHandleHitWidth,
                height: height,
                alignment: .topLeading
            )
            .position(x: sidebarWidth + (AppWindowView.sidebarDividerWidth / 2), y: height / 2)
            .allowsHitTesting(false)

            BoundaryInteractionOverlay(descriptors: [boundaryDescriptor])
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear {
            releaseInteraction()
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
                updateInteraction(dragging: true)
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
                updateInteraction(dragging: false)
            },
            onHoverChanged: { hovering in
                updateInteraction(hovered: hovering)
            }
        )
    }

    private var boundaryID: String {
        "sidebar.resize.\(windowID.uuidString)"
    }

    private var highlighted: Bool {
        hovered || dragging
    }
}

private extension SidebarResizeLayer {
    func updateInteraction(
        hovered: Bool? = nil,
        dragging: Bool? = nil
    ) {
        self.hovered = hovered ?? self.hovered
        self.dragging = dragging ?? self.dragging
    }

    func releaseInteraction() {
        resizeStartWidth = nil
        guard hovered || dragging else { return }

        DispatchQueue.main.async {
            hovered = false
            dragging = false
        }
    }
}

private struct PendingWorkspaceClose: Identifiable {
    let windowID: UUID
    let workspaceID: UUID
    let source: AppActionSource
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
