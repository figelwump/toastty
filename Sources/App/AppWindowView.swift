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
    var taskCoordinator: TaskCoordinator? = nil
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
    /// The width of the window's content, which limits the dock's width.
    @State private var windowContentWidth: CGFloat = 0
    @Environment(\.openWindow) private var openWindow

    static let sidebarResizeHandleHitWidth: CGFloat = 10
    static let sidebarDividerWidth: CGFloat = 1

    private var sidebarVisible: Bool {
        store.window(id: windowID)?.sidebarVisible ?? true
    }

    private var showsTasksView: Bool {
        store.window(id: windowID)?.showsTasksView ?? false
    }

    private var taskBoard: TaskBoardStore {
        taskCoordinator?.board ?? .disabled
    }

    private var coordinatorController: CoordinatorController? {
        taskCoordinator?.coordinatorController
    }

    /// The coordinator's dock shows in this window now.
    private var dockShows: Bool {
        coordinatorController?.dockShows(in: windowID) == true
    }

    /// The dock's toggle shows in the toolbar of the coordinator's window.
    private var showsDockToggle: Bool {
        guard let coordinatorController else { return false }
        return CoordinatorDockPresentation.showsToggle(
            windowID: windowID,
            coordinator: coordinatorController.location,
            chatAvailable: coordinatorController.chatIsAvailable
        )
    }

    /// The buttons at the titlebar's left, after the traffic lights.
    private var titlebarButtonCount: Int {
        showsDockToggle ? 4 : 3
    }

    /// The window's content width, or its saved frame width before the
    /// first layout reports one.
    private var dockLimitWindowWidth: Double {
        windowContentWidth > 0
            ? Double(windowContentWidth)
            : store.window(id: windowID)?.frame.width ?? 0
    }

    private var dockWidth: CGFloat {
        let width = dockLimitWindowWidth
        guard let window = store.window(id: windowID) else {
            return CGFloat(min(
                WindowState.defaultCoordinatorDockWidth,
                WindowState.maxCoordinatorDockWidth(windowWidth: width)
            ))
        }
        return CGFloat(window.coordinatorDockWidth(windowWidth: width))
    }

    private var columnResizeEdges: [ResizableColumnEdge] {
        var edges: [ResizableColumnEdge] = []
        var dividerX: CGFloat = 0
        if sidebarVisible {
            let sidebarWidth = effectiveSidebarWidth
            dividerX = sidebarWidth
            edges.append(ResizableColumnEdge(
                id: "sidebar.resize.\(windowID.uuidString)",
                dividerX: dividerX,
                columnWidth: sidebarWidth,
                accessibilityLabel: "Resize Sidebar",
                accessibilityIdentifier: "sidebar.resize",
                metadata: [
                    "windowID": windowID.uuidString,
                    "sidebarWidth": String(format: "%.1f", sidebarWidth),
                ],
                setWidth: { [store, windowID] width in
                    _ = store.send(.setSidebarWidth(
                        windowID: windowID,
                        width: width,
                        defaultWidth: Double(ToastyTheme.sidebarWidth)
                    ))
                }
            ))
            dividerX += Self.sidebarDividerWidth
        }
        if dockShows {
            let dockWidth = dockWidth
            dividerX += dockWidth
            edges.append(ResizableColumnEdge(
                id: "coordinator-dock.resize.\(windowID.uuidString)",
                dividerX: dividerX,
                columnWidth: dockWidth,
                accessibilityLabel: "Resize Coordinator Dock",
                accessibilityIdentifier: "coordinator.dock.resize",
                metadata: [
                    "windowID": windowID.uuidString,
                    "dockWidth": String(format: "%.1f", dockWidth),
                ],
                setWidth: { [store, windowID, dockLimitWindowWidth] width in
                    // A drag stops at this window's limit, so the saved
                    // width is one the user saw.
                    let limit = WindowState.maxCoordinatorDockWidth(windowWidth: dockLimitWindowWidth)
                    _ = store.send(.setCoordinatorDockWidth(windowID: windowID, width: min(width, limit)))
                }
            ))
        }
        return edges
    }

    private func requestWorkspaceMerge(workspaceID: UUID, mode: WorkspaceMergeMode) {
        workspaceMergeController.requestMerge(workspaceID: workspaceID, mode: mode)
    }

    private func requestWorkspaceClose(workspaceID: UUID) {
        workspaceMergeController.requestClose(workspaceID: workspaceID)
    }

    private func requestSessionClose(panelID: UUID, sessionTitle: String) {
        SessionCloseController(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            terminalCloseAssessment: { [terminalRuntimeRegistry] panelID in
                terminalRuntimeRegistry.terminalCloseConfirmationAssessment(panelID: panelID)
            },
            localDocumentCloseConfirmationState: { [webPanelRuntimeRegistry] panelID in
                webPanelRuntimeRegistry.localDocumentCloseConfirmationState(panelID: panelID)
            },
            taskSpaceCloseAsker: .live(sessionRuntimeStore: sessionRuntimeStore)
        ).closeSessionInteractively(panelID: panelID, sessionTitle: sessionTitle)
    }

    private var workspaceMergeController: WorkspaceMergeController {
        WorkspaceMergeController.live(store: store, sessionRuntimeStore: sessionRuntimeStore)
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
                        taskCoordinator: taskCoordinator,
                        taskBoard: taskBoard,
                        newTask: taskBoard.newTask,
                        terminalRuntimeContext: terminalRuntimeContext,
                        requestWorkspaceMerge: requestWorkspaceMerge,
                        requestWorkspaceClose: requestWorkspaceClose,
                        requestSessionClose: requestSessionClose
                    )
                    .frame(width: effectiveSidebarWidth)

                    Rectangle()
                        .fill(ToastyTheme.hairline)
                        .frame(width: Self.sidebarDividerWidth)
                }

                if #available(macOS 15.0, *), dockShows,
                   let coordinatorController, let chat = coordinatorController.chat,
                   let location = coordinatorController.location {
                    CoordinatorDockView(
                        controller: coordinatorController,
                        sessionRuntimeStore: sessionRuntimeStore,
                        store: store,
                        chat: chat,
                        board: taskBoard,
                        location: location,
                        headerLeadingInset: sidebarVisible
                            ? 14
                            : ToastyTheme.topBarLeadingPadding(titlebarButtonCount: titlebarButtonCount),
                        appIsActive: appIsActive
                    )
                    .frame(width: dockWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))

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
                    leftColumnVisible: sidebarVisible || dockShows,
                    titlebarButtonCount: titlebarButtonCount,
                    requestWorkspaceMerge: requestWorkspaceMerge,
                    requestWorkspaceClose: requestWorkspaceClose
                )
                // The Tasks view covers the workspace instead of replacing
                // it, so terminals stay attached while it shows. The dock
                // stays beside it.
                .overlay {
                    if showsTasksView, taskBoard.isEnabled {
                        TasksView(
                            windowID: windowID,
                            store: store,
                            board: taskBoard,
                            sessionRuntimeStore: sessionRuntimeStore,
                            newTask: taskBoard.newTask.map { action in { action() } },
                            newTaskShortcutLabel: taskBoard.newTaskShortcutLabel()
                        )
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: sidebarVisible)
            .animation(.easeInOut(duration: 0.15), value: dockShows)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                windowContentWidth = width
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    let edges = columnResizeEdges
                    if edges.isEmpty == false {
                        ColumnResizeLayer(
                            edges: edges,
                            height: geometry.size.height,
                            appIsActive: appIsActive
                        )
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: .topLeading
                        )
                    }
                }
            }

            // Shared window controls remain accessible with or without the sidebar.
            titlebarControls

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
        .onChange(of: dockShows) { _, shows in
            // A hidden dock takes its field, and maybe the keyboard, with
            // it: the keyboard goes back to the workspace's panel.
            if shows == false {
                scheduleWindowFocusRestore(avoidStealingKeyboardFocus: false)
            }
        }
        .onChange(of: showsTasksView) { _, isShown in
            // While shown, the Tasks view holds focus in this window and
            // focus restores skip the covered terminals.
            if isShown == false {
                scheduleWindowFocusRestore(avoidStealingKeyboardFocus: false)
            }
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
            let closeTarget = PendingWorkspaceClose(
                windowID: request.windowID,
                workspaceID: request.workspaceID,
                source: request.source,
                unsavedLocalDocumentDraftCount: closeConfirmationSummary.dirtyDraftCount,
                firstUnsavedLocalDocumentDisplayName: closeConfirmationSummary.firstDirtyDraftDisplayName,
                localDocumentSaveInProgressCount: closeConfirmationSummary.saveInProgressCount,
                firstLocalDocumentSaveInProgressDisplayName: closeConfirmationSummary.firstSaveInProgressDisplayName
            )
            // A task space whose task asks the close question asks it in
            // place of this confirmation. A save in progress still refuses.
            if closeTarget.allowsDestructiveConfirmation,
               sessionRuntimeStore.taskSpaceCloseQuestion(workspaceID: request.workspaceID) != nil {
                Task { @MainActor in
                    askTaskSpaceCloseQuestion(closeTarget)
                }
                return
            }
            pendingWorkspaceClose = closeTarget
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
            if store.state.selectedWindowID == windowID {
                sessionRuntimeStore.acknowledgeViewedProgramStatusResults()
            }
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

    /// A window's sidebar width: the user's resized width, or the default.
    static func effectiveSidebarWidth(sidebarWidthPointsOverride: Double?) -> CGFloat {
        if let override = WindowState.normalizedSidebarWidthOverride(sidebarWidthPointsOverride) {
            return CGFloat(override)
        }
        return ToastyTheme.sidebarWidth
    }

    static func sidebarResizeHandleFrame(
        sidebarWidth: CGFloat,
        height: CGFloat
    ) -> CGRect {
        columnResizeHandleFrame(dividerX: sidebarWidth, height: height)
    }

    /// The area that takes a drag on a column's divider, centered on it.
    static func columnResizeHandleFrame(
        dividerX: CGFloat,
        height: CGFloat
    ) -> CGRect {
        let dividerCenterX = dividerX + (Self.sidebarDividerWidth / 2)
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

    private var titlebarControls: some View {
        HStack(spacing: ToastyTheme.titlebarControlSpacing) {
            sidebarToggleButton
            if showsDockToggle, let coordinatorController {
                CoordinatorDockToggleButton(
                    controller: coordinatorController,
                    sessionRuntimeStore: sessionRuntimeStore,
                    store: store,
                    windowID: windowID
                )
            }
            navigationButton(
                symbol: "chevron.left",
                label: "Go Back",
                help: store.navigationBackHelp,
                enabled: store.canNavigateBack,
                identifier: "titlebar.navigation.back"
            ) { _ = store.navigateBack() }
            navigationButton(
                symbol: "chevron.right",
                label: "Go Forward",
                help: store.navigationForwardHelp,
                enabled: store.canNavigateForward,
                identifier: "titlebar.navigation.forward"
            ) { _ = store.navigateForward() }
        }
        .padding(.leading, ToastyTheme.titlebarSidebarToggleLeadingPadding)
        .padding(.top, ToastyTheme.titlebarSidebarToggleTopPadding)
    }

    private func navigationButton(
        symbol: String,
        label: String,
        help: String,
        enabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ToastyTheme.inactiveText.opacity(enabled ? 1 : 0.35))
                .frame(
                    width: ToastyTheme.titlebarSidebarToggleButtonSize,
                    height: ToastyTheme.titlebarSidebarToggleButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(enabled == false)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
        .accessibilityIdentifier(identifier)
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
            sidebarWidthPointsOverride: store.window(id: windowID)?.sidebarWidthPointsOverride
        )
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

    private func askTaskSpaceCloseQuestion(_ closeTarget: PendingWorkspaceClose) {
        let asker = TaskSpaceCloseAsker.live(sessionRuntimeStore: sessionRuntimeStore)
        guard let answer = asker.ask(closingWorkspaceID: closeTarget.workspaceID, warning: { closeTarget.confirmationMessage }),
              answer.choice != nil,
              store.confirmWorkspaceClose(
                  windowID: closeTarget.windowID,
                  workspaceID: closeTarget.workspaceID,
                  source: closeTarget.source
              ) else { return }
        asker.taskSpaceClosed(answer)
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

/// A column whose right edge the user drags to set its width: the sidebar
/// or the coordinator's dock.
struct ResizableColumnEdge: Identifiable {
    let id: String
    /// Where the column's divider starts, in the window's content.
    let dividerX: CGFloat
    let columnWidth: CGFloat
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let metadata: [String: String]
    let setWidth: (Double) -> Void
}

/// The resize edges of the window's columns, in one overlay.
private struct ColumnResizeLayer: View {
    let edges: [ResizableColumnEdge]
    let height: CGFloat
    let appIsActive: Bool

    @State private var resizeStartWidth: Double?
    @State private var hoveredEdgeID: String?
    @State private var draggingEdgeID: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(edges) { edge in
                BoundaryResizeHandleVisual(
                    highlighted: hoveredEdgeID == edge.id || draggingEdgeID == edge.id,
                    appIsActive: appIsActive,
                    width: AppWindowView.sidebarDividerWidth
                )
                .frame(
                    width: AppWindowView.sidebarResizeHandleHitWidth,
                    height: height,
                    alignment: .topLeading
                )
                .position(x: edge.dividerX + (AppWindowView.sidebarDividerWidth / 2), y: height / 2)
                .allowsHitTesting(false)
            }

            BoundaryInteractionOverlay(descriptors: edges.map(boundaryDescriptor))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear {
            releaseInteraction()
        }
    }

    private func boundaryDescriptor(_ edge: ResizableColumnEdge) -> BoundaryInteractionDescriptor {
        BoundaryInteractionDescriptor(
            id: edge.id,
            hitFrame: AppWindowView.columnResizeHandleFrame(dividerX: edge.dividerX, height: height),
            visualFrame: CGRect(
                x: edge.dividerX,
                y: 0,
                width: AppWindowView.sidebarDividerWidth,
                height: height
            ),
            axis: .vertical,
            cursor: .resizeLeftRight,
            accessibilityLabel: edge.accessibilityLabel,
            accessibilityIdentifier: edge.accessibilityIdentifier,
            metadata: edge.metadata,
            onBegan: { _ in
                resizeStartWidth = Double(edge.columnWidth)
                draggingEdgeID = edge.id
            },
            onChanged: { value in
                guard let startingWidth = resizeStartWidth else { return }
                edge.setWidth(startingWidth + Double(value.translation.width))
            },
            onEnded: { _ in
                resizeStartWidth = nil
                draggingEdgeID = nil
            },
            onHoverChanged: { hovering in
                if hovering {
                    hoveredEdgeID = edge.id
                } else if hoveredEdgeID == edge.id {
                    hoveredEdgeID = nil
                }
            }
        )
    }

    private func releaseInteraction() {
        resizeStartWidth = nil
        guard hoveredEdgeID != nil || draggingEdgeID != nil else { return }

        DispatchQueue.main.async {
            hoveredEdgeID = nil
            draggingEdgeID = nil
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
