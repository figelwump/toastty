import Combine
import CoreState
import Foundation

@MainActor
final class WebPanelRuntimeRegistry: ObservableObject {
    private weak var store: AppStore?
    private var stateObservation: AnyCancellable?
    private var browserRuntimeByPanelID: [UUID: BrowserPanelRuntime] = [:]

    func bind(store: AppStore) {
        if let existingStore = self.store {
            precondition(existingStore === store, "WebPanelRuntimeRegistry cannot be rebound to a different AppStore.")
        }
        self.store = store
        bindStateObservation(to: store)
    }

    func browserRuntime(
        for panelID: UUID,
        state: WebPanelState
    ) -> BrowserPanelRuntime {
        _ = state
        if let runtime = browserRuntimeByPanelID[panelID] {
            return runtime
        }

        let runtime = BrowserPanelRuntime(panelID: panelID) { [weak self] panelID, title, url in
            guard let self else { return }
            _ = self.store?.send(.updateWebPanelMetadata(panelID: panelID, title: title, url: url))
        }
        browserRuntimeByPanelID[panelID] = runtime
        return runtime
    }
}

private extension WebPanelRuntimeRegistry {
    func bindStateObservation(to store: AppStore) {
        stateObservation?.cancel()
        synchronize(with: store.state)
        stateObservation = store.$state.sink { [weak self] state in
            self?.synchronize(with: state)
        }
    }

    func synchronize(with state: AppState) {
        let liveBrowserPanelIDs = liveBrowserPanelIDs(in: state)
        browserRuntimeByPanelID = browserRuntimeByPanelID.filter { panelID, _ in
            liveBrowserPanelIDs.contains(panelID)
        }
    }

    func liveBrowserPanelIDs(in state: AppState) -> Set<UUID> {
        state.workspacesByID.values.reduce(into: Set<UUID>()) { result, workspace in
            for tab in workspace.orderedTabs {
                for (panelID, panelState) in tab.panels {
                    guard case .web(let webState) = panelState,
                          webState.definition == .browser else {
                        continue
                    }
                    result.insert(panelID)
                }
            }
        }
    }
}
