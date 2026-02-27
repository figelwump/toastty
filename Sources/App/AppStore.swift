import CoreState
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var state: AppState

    private let reducer = AppReducer()

    init(state: AppState = .bootstrap()) {
        self.state = state
    }

    func send(_ action: AppAction) {
        var next = state
        guard reducer.send(action, state: &next) else { return }
        state = next
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
