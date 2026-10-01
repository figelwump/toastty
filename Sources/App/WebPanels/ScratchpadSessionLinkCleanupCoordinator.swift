import Combine
import CoreState
import Foundation

@MainActor
final class ScratchpadSessionLinkCleanupCoordinator {
    private static let cleanupDelayNanoseconds: UInt64 = 250_000_000

    private let store: AppStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private let documentStore: ScratchpadDocumentStore
    private let cleanupDelayNanoseconds: UInt64
    private var registryObservation: AnyCancellable?
    private var storeActionObserverToken: UUID?
    private var cleanupTask: Task<Void, Never>?
    private var activeSessionIDs: Set<String>

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        documentStore: ScratchpadDocumentStore,
        cleanupDelayNanoseconds: UInt64 = ScratchpadSessionLinkCleanupCoordinator.cleanupDelayNanoseconds
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.documentStore = documentStore
        self.cleanupDelayNanoseconds = cleanupDelayNanoseconds
        activeSessionIDs = Self.activeSessionIDs(in: sessionRuntimeStore.sessionRegistry)
        registryObservation = sessionRuntimeStore.$sessionRegistry
            .dropFirst()
            .sink { [weak self] registry in
                self?.handleSessionRegistryChange(registry)
            }
        storeActionObserverToken = store.addActionAppliedObserver { [weak self] action, previousState, nextState in
            switch action {
            case .closePanel, .closeRightAuxPanelTab, .closeWorkspaceTab, .closeWorkspace, .closeWindow,
                 .movePanelToSlot, .movePanelToWorkspace, .detachPanelToNewWindow:
                self?.clearRemovedBindings(previousState: previousState, nextState: nextState)
                self?.cleanupNow(reason: "layout_changed")
            default:
                break
            }
        }
        scheduleCleanup(reason: "initial_bootstrap")
    }

    deinit {
        cleanupTask?.cancel()
        if let token = storeActionObserverToken {
            Task { @MainActor [store] in store.removeActionAppliedObserver(token) }
        }
    }

    private func clearRemovedBindings(previousState: AppState, nextState: AppState) {
        func linkedDocuments(in state: AppState) -> [UUID: ScratchpadSessionLink] {
            var result: [UUID: ScratchpadSessionLink] = [:]
            for workspace in state.workspacesByID.values {
                for panel in workspace.allPanelsByID.values {
                    guard case .web(let web) = panel, web.definition == .scratchpad,
                          let scratchpad = web.scratchpad, let link = scratchpad.sessionLink else { continue }
                    result[scratchpad.documentID] = link
                }
            }
            return result
        }
        let remaining = linkedDocuments(in: nextState)
        for (documentID, link) in linkedDocuments(in: previousState) where remaining[documentID] == nil {
            do {
                // A document may be missing or already rebound; closing must not erase a newer link.
                guard let document = try documentStore.load(documentID: documentID),
                      document.sessionLink == link else { continue }
                _ = try documentStore.updateSessionLink(documentID: documentID, sessionLink: nil)
            } catch {
                ToasttyLog.warning(
                    "Failed to clear a closed Scratchpad document's session link",
                    category: .state,
                    metadata: ["document_id": documentID.uuidString, "error": error.localizedDescription]
                )
            }
        }
    }

    private func handleSessionRegistryChange(_ registry: SessionRegistry) {
        let nextActiveSessionIDs = Self.activeSessionIDs(in: registry)
        let didLoseActiveSession = activeSessionIDs.subtracting(nextActiveSessionIDs).isEmpty == false
        activeSessionIDs = nextActiveSessionIDs

        guard didLoseActiveSession else { return }
        scheduleCleanup(reason: "active_session_removed")
    }

    private func scheduleCleanup(reason: String) {
        guard cleanupTask == nil else { return }
        cleanupTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.cleanupDelayNanoseconds ?? 0)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            self?.cleanupNow(reason: reason)
            self?.cleanupTask = nil
        }
    }

    private func cleanupNow(reason: String) {
        let outcome = store.cleanupStaleScratchpadSessionLinks(
            sessionRegistry: sessionRuntimeStore.sessionRegistry,
            documentStore: documentStore
        )

        if outcome.didClearLinks {
            ToasttyLog.info(
                "Cleared stale Scratchpad session links",
                category: .state,
                metadata: [
                    "reason": reason,
                    "cleared_panel_count": "\(outcome.clearedPanelIDs.count)",
                    "cleared_document_count": "\(outcome.clearedDocumentIDs.count)",
                    "cleared_panel_ids": outcome.clearedPanelIDs
                        .map(\.uuidString)
                        .sorted()
                        .joined(separator: ","),
                ]
            )
        }

        if outcome.failures.isEmpty == false {
            ToasttyLog.warning(
                "Failed to clear some stale Scratchpad session links",
                category: .state,
                metadata: [
                    "reason": reason,
                    "failure_count": "\(outcome.failures.count)",
                    "failed_panel_ids": outcome.failures
                        .map { $0.panelID.uuidString }
                        .sorted()
                        .joined(separator: ","),
                ]
            )
        }
    }

    private static func activeSessionIDs(in registry: SessionRegistry) -> Set<String> {
        Set(registry.activeSessionIDByPanelID.values)
    }
}
