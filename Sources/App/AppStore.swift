import CoreState
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var state: AppState

    private let reducer = AppReducer()

    init(state: AppState = .bootstrap()) {
        self.state = state
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
        guard reducer.send(action, state: &next) else {
            ToasttyLog.warning(
                "Reducer rejected app action",
                category: .store,
                metadata: ["action": actionName]
            )
            return false
        }
        state = next
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

    var selectedWindow: WindowState? {
        guard let selectedWindowID = state.selectedWindowID else { return nil }
        return state.windows.first(where: { $0.id == selectedWindowID })
    }

    var selectedWorkspace: WorkspaceState? {
        guard let window = selectedWindow,
              let workspaceID = window.selectedWorkspaceID else { return nil }
        return state.workspacesByID[workspaceID]
    }
}
