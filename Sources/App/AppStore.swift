import AppKit
import CoreState
import Foundation

struct WindowCommandSelection {
    let windowID: UUID
    let window: WindowState
    let workspace: WorkspaceState
}

struct PendingWorkspaceCloseRequest: Equatable {
    let windowID: UUID
    let workspaceID: UUID
}

private enum WorkspaceCommandTarget {
    case existingWindow(UUID)
    case newWindow
}

@MainActor
final class AppStore: ObservableObject {
    typealias ActionAppliedObserver = @MainActor (AppAction, AppState, AppState) -> Void
    typealias CommandCreateWindowFrameProvider = @MainActor () -> CGRectCodable?

    @Published private(set) var state: AppState

    /// Set by workspace creation or rename commands; the sidebar observes this
    /// to enter inline-rename mode for the target workspace.
    @Published var pendingRenameWorkspaceID: UUID?
    @Published var pendingCloseWorkspaceRequest: PendingWorkspaceCloseRequest?

    private let reducer = AppReducer()
    private let persistTerminalFontPreference: Bool
    private let commandCreateWindowFrameProvider: CommandCreateWindowFrameProvider
    private var actionAppliedObservers: [UUID: ActionAppliedObserver] = [:]

    init(
        state: AppState = .bootstrap(),
        persistTerminalFontPreference: Bool = true,
        commandCreateWindowFrameProvider: @escaping CommandCreateWindowFrameProvider = AppStore.currentCommandCreateWindowFrame
    ) {
        self.state = state
        self.persistTerminalFontPreference = persistTerminalFontPreference
        self.commandCreateWindowFrameProvider = commandCreateWindowFrameProvider
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
        persistTerminalFontPreferenceIfNeeded(action: action, previousState: previousState, nextState: next)
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
                    initialWorkspaceTitle: nil,
                    initialFrame: commandCreateWindowFrameProvider()
                )
            )
        }
    }

    func renameSelectedWorkspaceFromCommand(preferredWindowID: UUID?) {
        guard let selection = commandSelection(preferredWindowID: preferredWindowID) else { return }
        pendingRenameWorkspaceID = selection.workspace.id
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

    @discardableResult
    func confirmWorkspaceClose(windowID: UUID, workspaceID: UUID) -> Bool {
        let request = PendingWorkspaceCloseRequest(windowID: windowID, workspaceID: workspaceID)
        if pendingCloseWorkspaceRequest == request {
            pendingCloseWorkspaceRequest = nil
        }
        guard let selection = state.workspaceSelection(containingWorkspaceID: workspaceID),
              selection.windowID == windowID else { return false }
        let didCloseWorkspace = send(.closeWorkspace(workspaceID: workspaceID))
        if didCloseWorkspace, pendingRenameWorkspaceID == workspaceID {
            pendingRenameWorkspaceID = nil
        }
        return didCloseWorkspace
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

    private func persistTerminalFontPreferenceIfNeeded(action: AppAction, previousState: AppState, nextState: AppState) {
        guard persistTerminalFontPreference else { return }
        guard abs(previousState.globalTerminalFontPoints - nextState.globalTerminalFontPoints) >=
            AppState.terminalFontComparisonEpsilon else {
            return
        }

        switch action {
        case .resetGlobalTerminalFont:
            ToasttySettingsStore.persistTerminalFontSizePoints(nil)
        case .increaseGlobalTerminalFont, .decreaseGlobalTerminalFont, .setGlobalTerminalFont:
            ToasttySettingsStore.persistTerminalFontSizePoints(nextState.globalTerminalFontPoints)
        default:
            break
        }
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

    private static func currentCommandCreateWindowFrame() -> CGRectCodable? {
        if let frame = NSApp.mainWindow?.frame {
            return CGRectCodable(frame)
        }
        if let frame = NSApp.keyWindow?.frame {
            return CGRectCodable(frame)
        }
        return nil
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
