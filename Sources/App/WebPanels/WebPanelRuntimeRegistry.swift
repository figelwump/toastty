import Combine
import CoreState
import Foundation

struct LocalDocumentCloseConfirmationSummary: Equatable, Sendable {
    let dirtyDraftCount: Int
    let firstDirtyDraftDisplayName: String?
    let saveInProgressCount: Int
    let firstSaveInProgressDisplayName: String?

    static let none = LocalDocumentCloseConfirmationSummary(
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
    private var localDocumentRuntimeByPanelID: [UUID: LocalDocumentPanelRuntime] = [:]
    private var localDocumentRuntimeObservationByPanelID: [UUID: AnyCancellable] = [:]
    private var pendingLocalDocumentRevealLineByPanelID: [UUID: Int] = [:]
    private var scratchpadRuntimeByPanelID: [UUID: ScratchpadPanelRuntime] = [:]
    private var scratchpadRuntimeObservationByPanelID: [UUID: AnyCancellable] = [:]
    let scratchpadDocumentStore: ScratchpadDocumentStore

    init(scratchpadDocumentStore: ScratchpadDocumentStore = ScratchpadDocumentStore()) {
        self.scratchpadDocumentStore = scratchpadDocumentStore
    }

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
            },
            openSecondaryURL: { [weak self] panelID, url in
                guard let self,
                      let store = self.store else {
                    return false
                }

                let preferredWindowID = store.state.workspaceSelection(containingPanelID: panelID)?.windowID
                return AppURLRouter.open(
                    url,
                    preferredWindowID: preferredWindowID,
                    appStore: store,
                    requestLocalDocumentReveal: { [weak self] panelID, lineNumber in
                        self?.requestLocalDocumentReveal(panelID: panelID, lineNumber: lineNumber) ?? false
                    }
                )
            }
        )
        browserRuntimeByPanelID[panelID] = runtime
        browserRuntimeObservationByPanelID[panelID] = runtime.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return runtime
    }

    func localDocumentRuntime(for panelID: UUID) -> LocalDocumentPanelRuntime {
        if let runtime = localDocumentRuntimeByPanelID[panelID] {
            return runtime
        }

        let runtime = LocalDocumentPanelRuntime(
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
        localDocumentRuntimeByPanelID[panelID] = runtime
        localDocumentRuntimeObservationByPanelID[panelID] = runtime.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if let pendingRevealLine = pendingLocalDocumentRevealLineByPanelID.removeValue(forKey: panelID) {
            runtime.requestReveal(lineNumber: pendingRevealLine)
        }
        return runtime
    }

    func loadedLocalDocumentRuntime(for panelID: UUID) -> LocalDocumentPanelRuntime? {
        localDocumentRuntimeByPanelID[panelID]
    }

    func scratchpadRuntime(for panelID: UUID) -> ScratchpadPanelRuntime {
        if let runtime = scratchpadRuntimeByPanelID[panelID] {
            return runtime
        }

        let runtime = ScratchpadPanelRuntime(
            panelID: panelID,
            documentStore: scratchpadDocumentStore,
            metadataDidChange: { [weak self] panelID, title, url in
                guard let self else { return }
                _ = self.store?.send(.updateWebPanelMetadata(panelID: panelID, title: title, url: url))
            },
            interactionDidRequestFocus: { [weak self] panelID in
                guard let self else { return }
                _ = self.store?.focusPanel(containing: panelID)
            }
        )
        scratchpadRuntimeByPanelID[panelID] = runtime
        scratchpadRuntimeObservationByPanelID[panelID] = runtime.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return runtime
    }

    func loadedScratchpadRuntime(for panelID: UUID) -> ScratchpadPanelRuntime? {
        scratchpadRuntimeByPanelID[panelID]
    }

    func canEnterEditingLocalDocumentPanel(panelID: UUID) -> Bool {
        localDocumentRuntimeByPanelID[panelID]?.canEnterEditFromCommand() == true
    }

    func canSaveLocalDocumentPanel(panelID: UUID) -> Bool {
        localDocumentRuntimeByPanelID[panelID]?.canSaveFromCommand() == true
    }

    func canCancelEditingLocalDocumentPanel(panelID: UUID) -> Bool {
        localDocumentRuntimeByPanelID[panelID]?.canCancelEditFromCommand() == true
    }

    func localDocumentSearchState(panelID: UUID) -> LocalDocumentSearchState? {
        localDocumentRuntimeByPanelID[panelID]?.searchState()
    }

    func isLocalDocumentSearchFieldFocused(panelID: UUID) -> Bool {
        localDocumentRuntimeByPanelID[panelID]?.isSearchFieldFocused() == true
    }

    @discardableResult
    func enterEditingLocalDocumentPanel(panelID: UUID) -> Bool {
        localDocumentRuntimeByPanelID[panelID]?.enterEditFromCommand() == true
    }

    @discardableResult
    func saveLocalDocumentPanel(panelID: UUID) -> Bool {
        localDocumentRuntimeByPanelID[panelID]?.saveFromCommand() == true
    }

    @discardableResult
    func cancelEditingLocalDocumentPanel(panelID: UUID) -> Bool {
        localDocumentRuntimeByPanelID[panelID]?.cancelEditFromCommand() == true
    }

    @discardableResult
    func startSearchLocalDocumentPanel(panelID: UUID) -> Bool {
        localDocumentRuntime(for: panelID).startSearch()
    }

    func updateSearchQueryLocalDocumentPanel(_ query: String, panelID: UUID) {
        localDocumentRuntime(for: panelID).updateSearchQuery(query)
    }

    @discardableResult
    func findNextLocalDocumentPanel(panelID: UUID) -> Bool {
        localDocumentRuntimeByPanelID[panelID]?.findNext() == true
    }

    @discardableResult
    func findPreviousLocalDocumentPanel(panelID: UUID) -> Bool {
        localDocumentRuntimeByPanelID[panelID]?.findPrevious() == true
    }

    @discardableResult
    func endSearchLocalDocumentPanel(panelID: UUID) -> Bool {
        localDocumentRuntimeByPanelID[panelID]?.endSearch() == true
    }

    @discardableResult
    func restoreLocalDocumentFocusAfterSearch(panelID: UUID) -> Bool {
        localDocumentRuntimeByPanelID[panelID]?.focusWebView() == true
    }

    func localDocumentCloseConfirmationState(panelID: UUID) -> LocalDocumentCloseConfirmationState? {
        localDocumentRuntimeByPanelID[panelID]?.closeConfirmationState()
    }

    func localDocumentCloseConfirmationSummary(panelIDs: some Sequence<UUID>) -> LocalDocumentCloseConfirmationSummary {
        var dirtyDraftCount = 0
        var firstDirtyDraftDisplayName: String?
        var saveInProgressCount = 0
        var firstSaveInProgressDisplayName: String?

        for panelID in panelIDs {
            guard let state = localDocumentCloseConfirmationState(panelID: panelID) else {
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
        return LocalDocumentCloseConfirmationSummary(
            dirtyDraftCount: dirtyDraftCount,
            firstDirtyDraftDisplayName: firstDirtyDraftDisplayName,
            saveInProgressCount: saveInProgressCount,
            firstSaveInProgressDisplayName: firstSaveInProgressDisplayName
        )
    }

    @discardableResult
    func requestLocalDocumentReveal(panelID: UUID, lineNumber: Int) -> Bool {
        guard lineNumber > 0,
              let store else {
            return false
        }

        let liveLocalDocumentPanelIDs = liveLocalDocumentPanelIDs(in: store.state)
        guard liveLocalDocumentPanelIDs.contains(panelID) else {
            return false
        }

        if let runtime = localDocumentRuntimeByPanelID[panelID] {
            runtime.requestReveal(lineNumber: lineNumber)
        } else {
            pendingLocalDocumentRevealLineByPanelID[panelID] = lineNumber
        }
        return true
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

        let liveLocalDocumentPanelIDs = liveLocalDocumentPanelIDs(in: state)
        localDocumentRuntimeByPanelID = localDocumentRuntimeByPanelID.filter { panelID, _ in
            liveLocalDocumentPanelIDs.contains(panelID)
        }
        localDocumentRuntimeObservationByPanelID = localDocumentRuntimeObservationByPanelID.filter { panelID, _ in
            liveLocalDocumentPanelIDs.contains(panelID)
        }
        pendingLocalDocumentRevealLineByPanelID = pendingLocalDocumentRevealLineByPanelID.filter { panelID, _ in
            liveLocalDocumentPanelIDs.contains(panelID)
        }

        let liveScratchpadPanelIDs = liveScratchpadPanelIDs(in: state)
        scratchpadRuntimeByPanelID = scratchpadRuntimeByPanelID.filter { panelID, _ in
            liveScratchpadPanelIDs.contains(panelID)
        }
        scratchpadRuntimeObservationByPanelID = scratchpadRuntimeObservationByPanelID.filter { panelID, _ in
            liveScratchpadPanelIDs.contains(panelID)
        }
    }

    func liveBrowserPanelIDs(in state: AppState) -> Set<UUID> {
        state.workspacesByID.values.reduce(into: Set<UUID>()) { result, workspace in
            for (panelID, panelState) in workspace.allPanelsByID {
                guard case .web(let webState) = panelState,
                      webState.definition == .browser else {
                    continue
                }
                result.insert(panelID)
            }
        }
    }

    func liveLocalDocumentPanelIDs(in state: AppState) -> Set<UUID> {
        state.workspacesByID.values.reduce(into: Set<UUID>()) { result, workspace in
            for (panelID, panelState) in workspace.allPanelsByID {
                guard case .web(let webState) = panelState,
                      webState.definition == .localDocument else {
                    continue
                }
                result.insert(panelID)
            }
        }
    }

    func liveScratchpadPanelIDs(in state: AppState) -> Set<UUID> {
        state.workspacesByID.values.reduce(into: Set<UUID>()) { result, workspace in
            for tab in workspace.orderedTabs {
                for (panelID, panelState) in tab.panels {
                    guard case .web(let webState) = panelState,
                          webState.definition == .scratchpad else {
                        continue
                    }
                    result.insert(panelID)
                }
            }
        }
    }
}
