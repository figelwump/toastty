import AppKit
import CoreState
import Foundation

enum TabNavigationDirection: Equatable {
    case previous
    case next
}

struct WindowCommandSelection {
    let windowID: UUID
    let window: WindowState
    let workspace: WorkspaceState
}

struct PendingWorkspaceCloseRequest: Equatable {
    let windowID: UUID
    let workspaceID: UUID
}

struct PendingWorkspaceRenameRequest: Equatable {
    let windowID: UUID
    let workspaceID: UUID
}

struct PendingWorkspaceTabRenameRequest: Equatable {
    let windowID: UUID
    let workspaceID: UUID
    let tabID: UUID
}

struct PendingSidebarSessionFlashRequest: Equatable {
    let requestID: UUID
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID?
}

struct PendingPanelFlashRequest: Equatable {
    let requestID: UUID
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
}

private enum WorkspaceCommandTarget {
    case existingWindow(UUID)
    case newWindow
}

@MainActor
final class AppStore: ObservableObject {
    typealias ActionAppliedObserver = @MainActor (AppAction, AppState, AppState) -> Void
    typealias CommandCreateWindowFrameProvider = @MainActor () -> CGRectCodable?
    typealias WindowActivationHandler = @MainActor (UUID) -> Void
    private static let newWindowCascadeOffset: Double = 30
    static let nextUnreadOrActionRequiredFallbackStatusKinds: Set<SessionStatusKind> = [
        .needsApproval,
        .error,
    ]
    static let nextUnreadOrWorkingFallbackStatusKinds: Set<SessionStatusKind> = [.working]

    @Published private(set) var state: AppState
    @Published private(set) var hasEverLaunchedAgent: Bool

    /// Set by workspace rename commands; the sidebar in the target window
    /// observes this to enter inline-rename mode for the target workspace.
    @Published var pendingRenameWorkspaceRequest: PendingWorkspaceRenameRequest?
    /// Set by tab rename commands; the selected workspace view in the target
    /// window observes this to enter inline-rename mode for the target tab.
    @Published var pendingRenameWorkspaceTabRequest: PendingWorkspaceTabRenameRequest?
    @Published var pendingCloseWorkspaceRequest: PendingWorkspaceCloseRequest?
    /// Set by exhausted navigation commands so the target sidebar can briefly
    /// pulse the currently selected session row, or the workspace row when no
    /// session row is visible.
    @Published var pendingSidebarSessionFlashRequest: PendingSidebarSessionFlashRequest?
    /// Set by explicit panel navigation so the target workspace view can briefly
    /// pulse the destination terminal panel.
    @Published var pendingPanelFlashRequest: PendingPanelFlashRequest?

    private let reducer = AppReducer()
    private let persistUserSettings: Bool
    private let commandCreateWindowFrameProvider: CommandCreateWindowFrameProvider
    private let windowActivationHandler: WindowActivationHandler
    private var actionAppliedObservers: [UUID: ActionAppliedObserver] = [:]

    init(
        state: AppState = .bootstrap(),
        persistTerminalFontPreference: Bool = true,
        initialHasEverLaunchedAgent: Bool = false,
        commandCreateWindowFrameProvider: @escaping CommandCreateWindowFrameProvider = AppStore.currentCommandCreateWindowFrame,
        windowActivationHandler: @escaping WindowActivationHandler = AppStore.activateWindowInAppKit
    ) {
        self.state = state
        hasEverLaunchedAgent = initialHasEverLaunchedAgent
        // This flag suppresses all UserDefaults-backed writes in tests and automation runs.
        persistUserSettings = persistTerminalFontPreference
        self.commandCreateWindowFrameProvider = commandCreateWindowFrameProvider
        self.windowActivationHandler = windowActivationHandler
    }

    @discardableResult
    func send(_ action: AppAction) -> Bool {
        let actionName = action.logName
        ToasttyLog.debug(
            "Dispatching app action",
            category: .store,
            metadata: ["action": actionName]
        )
        var next = state
        let previousState = state
        guard reducer.send(action, state: &next) else {
            ToasttyLog.warning(
                "Reducer rejected app action",
                category: .store,
                metadata: ["action": actionName]
            )
            return false
        }
        state = next
        prunePendingCommandRequests()
        let observers = Array(actionAppliedObservers.values)
        for observer in observers {
            observer(action, previousState, next)
        }
        ToasttyLog.debug(
            "Applied app action",
            category: .store,
            metadata: [
                "action": actionName,
                "selected_window_id": state.selectedWindowID?.uuidString ?? "<none>",
            ]
        )
        return true
    }

    func replaceState(_ state: AppState) {
        self.state = state
    }

    func window(id windowID: UUID) -> WindowState? {
        state.window(id: windowID)
    }

    func selectedWorkspaceID(in windowID: UUID) -> UUID? {
        state.selectedWorkspaceID(in: windowID)
    }

    func selectedWorkspace(in windowID: UUID) -> WorkspaceState? {
        state.workspaceSelection(in: windowID)?.workspace
    }

    @discardableResult
    func selectWorkspace(
        windowID: UUID,
        workspaceID: UUID,
        preferringUnreadSessionPanelIn sessionRuntimeStore: SessionRuntimeStore?
    ) -> Bool {
        let previousWorkspaceID = selectedWorkspaceID(in: windowID)
        guard send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID)) else {
            return false
        }

        guard previousWorkspaceID != workspaceID,
              let sessionRuntimeStore,
              let workspace = state.workspacesByID[workspaceID],
              let preferredPanelID = sessionRuntimeStore.preferredUnreadStatusPanelID(in: workspace) else {
            return true
        }

        _ = send(.focusPanel(workspaceID: workspaceID, panelID: preferredPanelID))
        return true
    }

    func commandWindowID(preferredWindowID: UUID?) -> UUID? {
        guard case .existingWindow(let windowID)? = createWorkspaceCommandTarget(preferredWindowID: preferredWindowID) else {
            return nil
        }
        return windowID
    }

    func commandSelection(preferredWindowID: UUID?) -> WindowCommandSelection? {
        if let preferredWindowID {
            // A focused scene/window should be authoritative. If SwiftUI is still
            // tearing it down, disable the command rather than rerouting it to
            // whichever window happens to be globally selected next.
            guard let selection = state.workspaceSelection(in: preferredWindowID) else {
                return nil
            }
            return WindowCommandSelection(
                windowID: selection.windowID,
                window: selection.window,
                workspace: selection.workspace
            )
        }

        guard let selection = state.selectedWorkspaceSelection() else {
            return nil
        }

        return WindowCommandSelection(
            windowID: selection.windowID,
            window: selection.window,
            workspace: selection.workspace
        )
    }

    func canCreateWorkspaceFromCommand(preferredWindowID: UUID?) -> Bool {
        createWorkspaceCommandTarget(preferredWindowID: preferredWindowID) != nil
    }

    @discardableResult
    func createWorkspaceTabFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else {
            return false
        }

        return send(
            .createWorkspaceTab(
                workspaceID: selection.workspace.id,
                seed: windowLaunchSeed(from: selection)
            )
        )
    }

    func canFocusNextUnreadOrActivePanelFromCommand(
        preferredWindowID: UUID?,
        sessionRuntimeStore: SessionRuntimeStore?
    ) -> Bool {
        nextUnreadOrActivePanelTarget(
            preferredWindowID: preferredWindowID,
            sessionRuntimeStore: sessionRuntimeStore
        ) != nil
    }

    @discardableResult
    func focusNextUnreadOrActivePanelFromCommand(
        preferredWindowID: UUID?,
        sessionRuntimeStore: SessionRuntimeStore?
    ) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        guard let target = nextUnreadOrActivePanelTarget(
            preferredWindowID: preferredWindowID,
            sessionRuntimeStore: sessionRuntimeStore
        ) else {
            requestSidebarFlashForExhaustedUnreadOrActiveJump(
                selection: selection
            )
            return false
        }
        return focusPanelTarget(target, flashPanelOnSuccess: true)
    }

    @discardableResult
    func selectWorkspaceTabFromCommand(preferredWindowID: UUID?, shortcutNumber: Int) -> Bool {
        guard shortcutNumber > 0 else { return false }
        guard let workspace = commandSelection(preferredWindowID: preferredWindowID)?.workspace else {
            return false
        }
        let tabIndex = shortcutNumber - 1
        let orderedTabs = workspace.orderedTabs
        guard orderedTabs.indices.contains(tabIndex) else { return false }
        let targetTabID = orderedTabs[tabIndex].id
        if workspace.resolvedSelectedTabID == targetTabID {
            return true
        }
        return send(.selectWorkspaceTab(workspaceID: workspace.id, tabID: targetTabID))
    }

    @discardableResult
    func selectAdjacentWorkspaceTab(preferredWindowID: UUID?, direction: TabNavigationDirection) -> Bool {
        guard let workspace = commandSelection(preferredWindowID: preferredWindowID)?.workspace else {
            return false
        }
        let tabs = workspace.orderedTabs
        guard tabs.count > 1 else { return false }
        guard let selectedID = workspace.resolvedSelectedTabID,
              let currentIndex = tabs.firstIndex(where: { $0.id == selectedID }) else {
            return false
        }
        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
        case .next:
            nextIndex = currentIndex < tabs.count - 1 ? currentIndex + 1 : 0
        }
        return send(.selectWorkspaceTab(workspaceID: workspace.id, tabID: tabs[nextIndex].id))
    }

    @discardableResult
    func createWindowFromCommand(preferredWindowID: UUID?) -> Bool {
        let selection = commandSelection(preferredWindowID: preferredWindowID)
        return send(
            .createWindow(
                seed: windowLaunchSeed(from: selection),
                initialFrame: commandCreateWindowFrame(cascadingFromSourceWindow: selection != nil)
            )
        )
    }

    @discardableResult
    func createWorkspaceFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let target = createWorkspaceCommandTarget(preferredWindowID: preferredWindowID) else {
            return false
        }

        switch target {
        case .existingWindow(let windowID):
            return send(.createWorkspace(windowID: windowID, title: nil))
        case .newWindow:
            return send(
                .createWindow(
                    seed: nil,
                    initialFrame: commandCreateWindowFrame(cascadingFromSourceWindow: false)
                )
            )
        }
    }

    @discardableResult
    func renameSelectedWorkspaceFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else { return false }
        pendingRenameWorkspaceRequest = PendingWorkspaceRenameRequest(
            windowID: selection.windowID,
            workspaceID: selection.workspace.id
        )
        return true
    }

    func canRenameSelectedWorkspaceTabFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let workspace = commandSelection(preferredWindowID: preferredWindowID)?.workspace else { return false }
        guard let selectedTabID = workspace.resolvedSelectedTabID else {
            return false
        }
        return workspace.tab(id: selectedTabID) != nil
    }

    @discardableResult
    func renameSelectedWorkspaceTabFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else { return false }
        let workspace = selection.workspace
        guard let selectedTabID = workspace.resolvedSelectedTabID,
              workspace.tab(id: selectedTabID) != nil else {
            return false
        }
        pendingRenameWorkspaceTabRequest = PendingWorkspaceTabRenameRequest(
            windowID: selection.windowID,
            workspaceID: workspace.id,
            tabID: selectedTabID
        )
        return true
    }

    @discardableResult
    func requestWorkspaceClose(workspaceID: UUID) -> Bool {
        guard let selection = state.workspaceSelection(containingWorkspaceID: workspaceID) else { return false }
        return requestWorkspaceClose(
            windowID: selection.windowID,
            workspaceID: selection.workspaceID
        )
    }

    @discardableResult
    func closeSelectedWorkspaceFromCommand(preferredWindowID: UUID?) -> Bool {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else { return false }
        return requestWorkspaceClose(
            windowID: selection.windowID,
            workspaceID: selection.workspace.id
        )
    }

    func consumePendingWorkspaceCloseRequest(
        windowID: UUID
    ) -> PendingWorkspaceCloseRequest? {
        guard let request = pendingCloseWorkspaceRequest,
              request.windowID == windowID else { return nil }
        pendingCloseWorkspaceRequest = nil
        return request
    }

    func consumePendingWorkspaceRenameRequest(
        windowID: UUID
    ) -> PendingWorkspaceRenameRequest? {
        guard let request = pendingRenameWorkspaceRequest,
              request.windowID == windowID else { return nil }
        pendingRenameWorkspaceRequest = nil
        return request
    }

    func consumePendingWorkspaceTabRenameRequest(
        windowID: UUID
    ) -> PendingWorkspaceTabRenameRequest? {
        guard let request = pendingRenameWorkspaceTabRequest,
              request.windowID == windowID else { return nil }
        pendingRenameWorkspaceTabRequest = nil
        return request
    }

    func consumePendingSidebarSessionFlashRequest(
        windowID: UUID,
        requestID: UUID
    ) -> PendingSidebarSessionFlashRequest? {
        guard let request = pendingSidebarSessionFlashRequest,
              request.windowID == windowID,
              request.requestID == requestID else { return nil }
        pendingSidebarSessionFlashRequest = nil
        return request
    }

    func consumePendingPanelFlashRequest(
        windowID: UUID,
        requestID: UUID
    ) -> PendingPanelFlashRequest? {
        guard let request = pendingPanelFlashRequest,
              request.windowID == windowID,
              request.requestID == requestID else { return nil }
        pendingPanelFlashRequest = nil
        return request
    }

    @discardableResult
    func focusExplicitlyNavigatedPanel(
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID
    ) -> Bool {
        focusPanel(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            flashPanelOnSuccess: true
        )
    }

    @discardableResult
    func focusDroppedImagePanel(
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID
    ) -> Bool {
        focusPanel(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            flashPanelOnSuccess: false,
            alwaysActivateWindow: true
        )
    }

    @discardableResult
    func confirmWorkspaceClose(windowID: UUID, workspaceID: UUID) -> Bool {
        let request = PendingWorkspaceCloseRequest(windowID: windowID, workspaceID: workspaceID)
        if pendingCloseWorkspaceRequest == request {
            pendingCloseWorkspaceRequest = nil
        }
        guard let selection = state.workspaceSelection(containingWorkspaceID: workspaceID),
              selection.windowID == windowID else { return false }
        let didCloseWorkspace = send(.closeWorkspace(workspaceID: workspaceID))
        if didCloseWorkspace, pendingRenameWorkspaceRequest?.workspaceID == workspaceID {
            pendingRenameWorkspaceRequest = nil
        }
        return didCloseWorkspace
    }

    private func prunePendingCommandRequests() {
        if let request = pendingRenameWorkspaceRequest,
           pendingRenameWorkspaceRequestIsValid(request) == false {
            pendingRenameWorkspaceRequest = nil
        }

        if let request = pendingRenameWorkspaceTabRequest,
           pendingRenameWorkspaceTabRequestIsValid(request) == false {
            pendingRenameWorkspaceTabRequest = nil
        }

        if let request = pendingCloseWorkspaceRequest,
           pendingWorkspaceCloseRequestIsValid(request) == false {
            pendingCloseWorkspaceRequest = nil
        }

        if let request = pendingSidebarSessionFlashRequest,
           pendingSidebarSessionFlashRequestIsValid(request) == false {
            pendingSidebarSessionFlashRequest = nil
        }

        if let request = pendingPanelFlashRequest,
           pendingPanelFlashRequestIsValid(request) == false {
            pendingPanelFlashRequest = nil
        }
    }

    private func pendingRenameWorkspaceRequestIsValid(_ request: PendingWorkspaceRenameRequest) -> Bool {
        pendingWorkspaceRequestExists(windowID: request.windowID, workspaceID: request.workspaceID)
    }

    private func pendingRenameWorkspaceTabRequestIsValid(_ request: PendingWorkspaceTabRenameRequest) -> Bool {
        guard pendingWorkspaceRequestExists(windowID: request.windowID, workspaceID: request.workspaceID),
              let workspace = state.workspacesByID[request.workspaceID] else {
            return false
        }
        return workspace.tab(id: request.tabID) != nil
    }

    private func pendingWorkspaceCloseRequestIsValid(_ request: PendingWorkspaceCloseRequest) -> Bool {
        pendingWorkspaceRequestExists(windowID: request.windowID, workspaceID: request.workspaceID)
    }

    private func pendingSidebarSessionFlashRequestIsValid(
        _ request: PendingSidebarSessionFlashRequest
    ) -> Bool {
        guard pendingWorkspaceRequestExists(windowID: request.windowID, workspaceID: request.workspaceID),
              let workspace = state.workspacesByID[request.workspaceID] else {
            return false
        }
        guard let panelID = request.panelID else {
            return true
        }
        return workspace.panelState(for: panelID) != nil
    }

    private func pendingPanelFlashRequestIsValid(_ request: PendingPanelFlashRequest) -> Bool {
        guard pendingWorkspaceRequestExists(windowID: request.windowID, workspaceID: request.workspaceID),
              let workspace = state.workspacesByID[request.workspaceID] else {
            return false
        }
        return workspace.panelState(for: request.panelID) != nil
    }

    private func pendingWorkspaceRequestExists(windowID: UUID, workspaceID: UUID) -> Bool {
        guard let window = state.window(id: windowID),
              window.workspaceIDs.contains(workspaceID),
              state.workspacesByID[workspaceID] != nil else {
            return false
        }
        return true
    }

    var selectedWindow: WindowState? {
        guard let selectedWindowID = state.selectedWindowID else { return nil }
        return state.window(id: selectedWindowID)
    }

    var selectedWorkspace: WorkspaceState? {
        state.selectedWorkspaceSelection()?.workspace
    }

    @discardableResult
    func addActionAppliedObserver(_ observer: @escaping ActionAppliedObserver) -> UUID {
        let token = UUID()
        actionAppliedObservers[token] = observer
        return token
    }

    func removeActionAppliedObserver(_ token: UUID) {
        actionAppliedObservers.removeValue(forKey: token)
    }

    func recordSuccessfulAgentLaunch() {
        guard hasEverLaunchedAgent == false else { return }
        hasEverLaunchedAgent = true
        guard persistUserSettings else { return }
        ToasttySettingsStore.persistHasEverLaunchedAgent(true)
    }

    private func createWorkspaceCommandTarget(preferredWindowID: UUID?) -> WorkspaceCommandTarget? {
        if let preferredWindowID {
            guard state.window(id: preferredWindowID) != nil else {
                return state.windows.isEmpty ? .newWindow : nil
            }
            return .existingWindow(preferredWindowID)
        }

        if let selectedWindowID = state.selectedWindowID,
           state.window(id: selectedWindowID) != nil {
            return .existingWindow(selectedWindowID)
        }

        if let firstWindowID = state.windows.first?.id {
            return .existingWindow(firstWindowID)
        }

        return .newWindow
    }

    private func nextUnreadOrActivePanelTarget(
        preferredWindowID: UUID?,
        sessionRuntimeStore: SessionRuntimeStore?
    ) -> PanelNavigationTarget? {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID),
              let selectedTabID = selection.workspace.resolvedSelectedTabID else {
            return nil
        }

        if let unreadTarget = state.nextUnreadPanel(
            fromWindowID: selection.windowID,
            workspaceID: selection.workspace.id,
            tabID: selectedTabID,
            focusedPanelID: selection.workspace.focusedPanelID
        ) {
            logNextUnreadOrActivePanelResolution(
                selection: selection,
                selectedTabID: selectedTabID,
                resolution: "unread",
                target: unreadTarget,
                sessionRuntimeStore: sessionRuntimeStore
            )
            return unreadTarget
        }

        guard let sessionRuntimeStore else {
            logNextUnreadOrActivePanelResolution(
                selection: selection,
                selectedTabID: selectedTabID,
                resolution: "none",
                target: nil,
                sessionRuntimeStore: nil
            )
            return nil
        }

        let attentionPanelIDs = sessionRuntimeStore.activePanelIDs(
            matching: Self.nextUnreadOrActionRequiredFallbackStatusKinds
        )
        if let target = nextUnreadOrActiveFallbackTarget(
            selection: selection,
            selectedTabID: selectedTabID,
            matchingPanelIDs: attentionPanelIDs
        ) {
            logNextUnreadOrActivePanelResolution(
                selection: selection,
                selectedTabID: selectedTabID,
                resolution: "fallback_attention",
                target: target,
                sessionRuntimeStore: sessionRuntimeStore
            )
            return target
        }

        let workingPanelIDs = sessionRuntimeStore.activePanelIDs(
            matching: Self.nextUnreadOrWorkingFallbackStatusKinds
        )
        let target = nextUnreadOrActiveFallbackTarget(
            selection: selection,
            selectedTabID: selectedTabID,
            matchingPanelIDs: workingPanelIDs
        )
        logNextUnreadOrActivePanelResolution(
            selection: selection,
            selectedTabID: selectedTabID,
            resolution: target == nil ? "none" : "fallback_working",
            target: target,
            sessionRuntimeStore: sessionRuntimeStore
        )
        return target
    }

    private func nextUnreadOrActiveFallbackTarget(
        selection: WindowCommandSelection,
        selectedTabID: UUID,
        matchingPanelIDs: Set<UUID>
    ) -> PanelNavigationTarget? {
        guard matchingPanelIDs.isEmpty == false else {
            return nil
        }

        return state.nextMatchingPanel(
            fromWindowID: selection.windowID,
            workspaceID: selection.workspace.id,
            tabID: selectedTabID,
            focusedPanelID: selection.workspace.focusedPanelID
        ) { _, panelID in
            matchingPanelIDs.contains(panelID)
        }
    }

    private func requestSidebarFlashForExhaustedUnreadOrActiveJump(
        selection: WindowCommandSelection
    ) {
        pendingSidebarSessionFlashRequest = PendingSidebarSessionFlashRequest(
            requestID: UUID(),
            windowID: selection.windowID,
            workspaceID: selection.workspace.id,
            panelID: selection.workspace.focusedPanelID
        )

        if let focusedPanelID = selection.workspace.focusedPanelID {
            requestPanelFlash(
                windowID: selection.windowID,
                workspaceID: selection.workspace.id,
                panelID: focusedPanelID
            )
        }
    }

    private func logNextUnreadOrActivePanelResolution(
        selection: WindowCommandSelection,
        selectedTabID: UUID,
        resolution: String,
        target: PanelNavigationTarget?,
        sessionRuntimeStore: SessionRuntimeStore?
    ) {
        let selectedTabUnreadPanelIDs = selection.workspace.tab(id: selectedTabID)?.unreadPanelIDs ?? []
        let workspaceUnreadPanelIDs = selection.workspace.unreadPanelIDs
        let attentionPanelStatuses = sessionRuntimeStore.map { runtimeStore in
            runtimeStore
                .activePanelIDs(matching: Self.nextUnreadOrActionRequiredFallbackStatusKinds)
                .sorted { $0.uuidString < $1.uuidString }
                .compactMap { panelID in
                    guard let status = runtimeStore.panelStatus(for: panelID)?.status.kind.rawValue else {
                        return nil
                    }
                    return "\(panelID.uuidString):\(status)"
                }
                .joined(separator: ",")
        } ?? ""
        let workingPanelStatuses = sessionRuntimeStore.map { runtimeStore in
            runtimeStore
                .activePanelIDs(matching: Self.nextUnreadOrWorkingFallbackStatusKinds)
                .sorted { $0.uuidString < $1.uuidString }
                .compactMap { panelID in
                    guard let status = runtimeStore.panelStatus(for: panelID)?.status.kind.rawValue else {
                        return nil
                    }
                    return "\(panelID.uuidString):\(status)"
                }
                .joined(separator: ",")
        } ?? ""

        var metadata: [String: String] = [
            "resolution": resolution,
            "window_id": selection.windowID.uuidString,
            "workspace_id": selection.workspace.id.uuidString,
            "selected_tab_id": selectedTabID.uuidString,
            "focused_panel_id": selection.workspace.focusedPanelID?.uuidString ?? "none",
            "selected_tab_unread_panel_ids": Self.commaSeparatedUUIDs(selectedTabUnreadPanelIDs),
            "workspace_unread_panel_ids": Self.commaSeparatedUUIDs(workspaceUnreadPanelIDs),
            "attention_panel_statuses": attentionPanelStatuses.isEmpty ? "none" : attentionPanelStatuses,
            "working_panel_statuses": workingPanelStatuses.isEmpty ? "none" : workingPanelStatuses,
        ]

        if let target {
            metadata["target_window_id"] = target.windowID.uuidString
            metadata["target_workspace_id"] = target.workspaceID.uuidString
            metadata["target_tab_id"] = target.tabID.uuidString
            metadata["target_panel_id"] = target.panelID.uuidString
            if let sessionRuntimeStore,
               let targetStatus = sessionRuntimeStore.panelStatus(for: target.panelID)?.status.kind.rawValue {
                metadata["target_status_kind"] = targetStatus
            }
        }

        ToasttyLog.debug(
            "Resolved next unread or active panel target",
            category: .store,
            metadata: metadata
        )
    }

    private static func commaSeparatedUUIDs<S: Sequence>(_ ids: S) -> String where S.Element == UUID {
        let values = ids.map(\.uuidString).sorted()
        return values.isEmpty ? "none" : values.joined(separator: ",")
    }

    @discardableResult
    private func focusPanelTarget(
        _ target: PanelNavigationTarget,
        flashPanelOnSuccess: Bool = false
    ) -> Bool {
        focusPanel(
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            panelID: target.panelID,
            flashPanelOnSuccess: flashPanelOnSuccess
        )
    }

    @discardableResult
    private func focusPanel(
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID,
        flashPanelOnSuccess: Bool,
        alwaysActivateWindow: Bool = false
    ) -> Bool {
        let previousSelectedWindowID = state.selectedWindowID
        let requiresWorkspaceSelection = state.selectedWorkspaceID(in: windowID) != workspaceID

        if state.selectedWindowID != windowID || requiresWorkspaceSelection {
            guard send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID)) else {
                return false
            }
        }

        guard send(.focusPanel(workspaceID: workspaceID, panelID: panelID)) else {
            return false
        }

        if let selectedWindowID = state.selectedWindowID,
           alwaysActivateWindow || selectedWindowID != previousSelectedWindowID {
            windowActivationHandler(selectedWindowID)
        }

        if flashPanelOnSuccess {
            requestPanelFlash(
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID
            )
        }

        return true
    }

    private func requestPanelFlash(windowID: UUID, workspaceID: UUID, panelID: UUID) {
        pendingPanelFlashRequest = PendingPanelFlashRequest(
            requestID: UUID(),
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID
        )
    }

    private func windowLaunchSeed(from selection: WindowCommandSelection?) -> WindowLaunchSeed? {
        guard let selection else { return nil }

        let windowFontOverride = state.normalizedTerminalFontOverride(
            state.effectiveTerminalFontPoints(for: selection.windowID)
        )

        guard let focusedPanelID = selection.workspace.focusedPanelID,
              case .terminal(let terminalState)? = selection.workspace.panels[focusedPanelID] else {
            guard let windowFontOverride else { return nil }
            return WindowLaunchSeed(windowTerminalFontSizePointsOverride: windowFontOverride)
        }

        return WindowLaunchSeed(
            terminalCWD: terminalState.workingDirectorySeed,
            terminalProfileBinding: terminalState.profileBinding ?? state.defaultTerminalProfileBinding,
            windowTerminalFontSizePointsOverride: windowFontOverride
        )
    }

    private func commandCreateWindowFrame(cascadingFromSourceWindow: Bool) -> CGRectCodable? {
        guard let frame = commandCreateWindowFrameProvider() else { return nil }
        guard cascadingFromSourceWindow else { return frame }
        return Self.cascadeWindowFrame(frame)
    }

    private static func currentCommandCreateWindowFrame() -> CGRectCodable? {
        if let frame = NSApp.mainWindow?.frame {
            return CGRectCodable(frame)
        }
        if let frame = NSApp.keyWindow?.frame {
            return CGRectCodable(frame)
        }
        return nil
    }

    private static func cascadeWindowFrame(_ frame: CGRectCodable) -> CGRectCodable {
        CGRectCodable(
            x: frame.x + newWindowCascadeOffset,
            y: frame.y - newWindowCascadeOffset,
            width: frame.width,
            height: frame.height
        )
    }

    private static func activateWindowInAppKit(id windowID: UUID) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowID.uuidString }) else {
            return
        }
        window.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    private func requestWorkspaceClose(windowID: UUID, workspaceID: UUID) -> Bool {
        guard let selection = state.workspaceSelection(containingWorkspaceID: workspaceID),
              selection.windowID == windowID else {
            return false
        }
        let request = PendingWorkspaceCloseRequest(windowID: windowID, workspaceID: workspaceID)
        if let pendingCloseWorkspaceRequest {
            return pendingCloseWorkspaceRequest == request
        }
        pendingCloseWorkspaceRequest = request
        return true
    }
}
