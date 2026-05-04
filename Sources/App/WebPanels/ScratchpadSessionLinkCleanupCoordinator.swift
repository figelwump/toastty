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
        scheduleCleanup(reason: "initial_bootstrap")
    }

    deinit {
        cleanupTask?.cancel()
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
