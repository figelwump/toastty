import Combine
import CoreState
import Foundation

struct MarkdownCloseConfirmationSummary: Equatable, Sendable {
    let dirtyDraftCount: Int
    let firstDirtyDraftDisplayName: String?
    let saveInProgressCount: Int
    let firstSaveInProgressDisplayName: String?

    static let none = MarkdownCloseConfirmationSummary(
        dirtyDraftCount: 0,
        firstDirtyDraftDisplayName: nil,
        saveInProgressCount: 0,
        firstSaveInProgressDisplayName: nil
    )

    var allowsDestructiveConfirmation: Bool {
        saveInProgressCount == 0
    }
}

@MainActor
final class WebPanelRuntimeRegistry: ObservableObject {
    private weak var store: AppStore?
    private var stateObservation: AnyCancellable?
    private var browserRuntimeByPanelID: [UUID: BrowserPanelRuntime] = [:]
    private var browserRuntimeObservationByPanelID: [UUID: AnyCancellable] = [:]
    private var markdownRuntimeByPanelID: [UUID: MarkdownPanelRuntime] = [:]
    private var markdownRuntimeObservationByPanelID: [UUID: AnyCancellable] = [:]

    func bind(store: AppStore) {
        if let existingStore = self.store {
            precondition(existingStore === store, "WebPanelRuntimeRegistry cannot be rebound to a different AppStore.")
        }
        self.store = store
        bindStateObservation(to: store)
    }

    func browserRuntime(for panelID: UUID) -> BrowserPanelRuntime {
        if let runtime = browserRuntimeByPanelID[panelID] {
            return runtime
        }

        let runtime = BrowserPanelRuntime(
            panelID: panelID,
            metadataDidChange: { [weak self] panelID, title, url in
                guard let self else { return }
                _ = self.store?.send(.updateWebPanelMetadata(panelID: panelID, title: title, url: url))
            },
            interactionDidRequestFocus: { [weak self] panelID in
                guard let self else { return }
                _ = self.store?.focusPanel(containing: panelID)
            }
        )
        browserRuntimeByPanelID[panelID] = runtime
        browserRuntimeObservationByPanelID[panelID] = runtime.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return runtime
    }

    func markdownRuntime(for panelID: UUID) -> MarkdownPanelRuntime {
        if let runtime = markdownRuntimeByPanelID[panelID] {
            return runtime
        }

        let runtime = MarkdownPanelRuntime(
            panelID: panelID,
            metadataDidChange: { [weak self] panelID, title, url in
                guard let self else { return }
                _ = self.store?.send(.updateWebPanelMetadata(panelID: panelID, title: title, url: url))
            },
            interactionDidRequestFocus: { [weak self] panelID in
                guard let self else { return }
                _ = self.store?.focusPanel(containing: panelID)
            }
        )
        markdownRuntimeByPanelID[panelID] = runtime
        markdownRuntimeObservationByPanelID[panelID] = runtime.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return runtime
    }

    func loadedMarkdownRuntime(for panelID: UUID) -> MarkdownPanelRuntime? {
        markdownRuntimeByPanelID[panelID]
    }

    func canSaveMarkdownPanel(panelID: UUID) -> Bool {
        markdownRuntimeByPanelID[panelID]?.canSaveFromCommand() == true
    }

    func canCancelEditingMarkdownPanel(panelID: UUID) -> Bool {
        markdownRuntimeByPanelID[panelID]?.canCancelEditFromCommand() == true
    }

    @discardableResult
    func saveMarkdownPanel(panelID: UUID) -> Bool {
        markdownRuntimeByPanelID[panelID]?.saveFromCommand() == true
    }

    @discardableResult
    func cancelEditingMarkdownPanel(panelID: UUID) -> Bool {
        markdownRuntimeByPanelID[panelID]?.cancelEditFromCommand() == true
    }

    func markdownCloseConfirmationState(panelID: UUID) -> MarkdownCloseConfirmationState? {
        markdownRuntimeByPanelID[panelID]?.closeConfirmationState()
    }

    func markdownCloseConfirmationSummary(panelIDs: some Sequence<UUID>) -> MarkdownCloseConfirmationSummary {
        var dirtyDraftCount = 0
        var firstDirtyDraftDisplayName: String?
        var saveInProgressCount = 0
        var firstSaveInProgressDisplayName: String?

        for panelID in panelIDs {
            guard let state = markdownCloseConfirmationState(panelID: panelID) else {
                continue
            }

            switch state.kind {
            case .dirtyDraft:
                dirtyDraftCount += 1
                if firstDirtyDraftDisplayName == nil {
                    firstDirtyDraftDisplayName = state.displayName
                }

            case .saveInProgress:
                saveInProgressCount += 1
                if firstSaveInProgressDisplayName == nil {
                    firstSaveInProgressDisplayName = state.displayName
                }
            }
        }

        guard dirtyDraftCount > 0 || saveInProgressCount > 0 else {
            return .none
        }
        return MarkdownCloseConfirmationSummary(
            dirtyDraftCount: dirtyDraftCount,
            firstDirtyDraftDisplayName: firstDirtyDraftDisplayName,
            saveInProgressCount: saveInProgressCount,
            firstSaveInProgressDisplayName: firstSaveInProgressDisplayName
        )
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
        browserRuntimeObservationByPanelID = browserRuntimeObservationByPanelID.filter { panelID, _ in
            liveBrowserPanelIDs.contains(panelID)
        }

        let liveMarkdownPanelIDs = liveMarkdownPanelIDs(in: state)
        markdownRuntimeByPanelID = markdownRuntimeByPanelID.filter { panelID, _ in
            liveMarkdownPanelIDs.contains(panelID)
        }
        markdownRuntimeObservationByPanelID = markdownRuntimeObservationByPanelID.filter { panelID, _ in
            liveMarkdownPanelIDs.contains(panelID)
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

    func liveMarkdownPanelIDs(in state: AppState) -> Set<UUID> {
        state.workspacesByID.values.reduce(into: Set<UUID>()) { result, workspace in
            for tab in workspace.orderedTabs {
                for (panelID, panelState) in tab.panels {
                    guard case .web(let webState) = panelState,
                          webState.definition == .localDocument else {
                        continue
                    }
                    result.insert(panelID)
                }
            }
        }
    }
}
