import CoreState
import Foundation

struct WindowCommandSelection {
    let windowID: UUID
    let window: WindowState
    let workspace: WorkspaceState
}

@MainActor
final class AppStore: ObservableObject {
    typealias ActionAppliedObserver = @MainActor (AppAction, AppState, AppState) -> Void

    @Published private(set) var state: AppState

    private let reducer = AppReducer()
    private let persistTerminalFontPreference: Bool
    private var actionAppliedObservers: [UUID: ActionAppliedObserver] = [:]

    init(
        state: AppState = .bootstrap(),
        persistTerminalFontPreference: Bool = true
    ) {
        self.state = state
        self.persistTerminalFontPreference = persistTerminalFontPreference
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
            ToasttyConfigStore.persistTerminalFontSizePoints(nil)
        case .increaseGlobalTerminalFont, .decreaseGlobalTerminalFont, .setGlobalTerminalFont:
            ToasttyConfigStore.persistTerminalFontSizePoints(nextState.globalTerminalFontPoints)
        default:
            break
        }
    }
}
