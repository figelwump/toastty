import Combine
import CoreState
import Foundation

/// Drops read-activity readers whose managed sessions have ended, so a
/// terminal's header eye clears once its last reader is gone.
@MainActor
final class TerminalReadActivityCleanupCoordinator {
    private let sessionRuntimeStore: SessionRuntimeStore
    private let readActivityStore: TerminalReadActivityStore
    private var registryObservation: AnyCancellable?
    private var liveSessionIDs: Set<String>

    init(
        sessionRuntimeStore: SessionRuntimeStore,
        readActivityStore: TerminalReadActivityStore
    ) {
        self.sessionRuntimeStore = sessionRuntimeStore
        self.readActivityStore = readActivityStore
        liveSessionIDs = Self.liveSessionIDs(in: sessionRuntimeStore.sessionRegistry)
        registryObservation = sessionRuntimeStore.$sessionRegistry
            .dropFirst()
            .sink { [weak self] registry in
                self?.handleSessionRegistryChange(registry)
            }
    }

    private func handleSessionRegistryChange(_ registry: SessionRegistry) {
        let next = Self.liveSessionIDs(in: registry)
        let didLoseSession = liveSessionIDs.subtracting(next).isEmpty == false
        liveSessionIDs = next
        guard didLoseSession else { return }
        readActivityStore.retainReaders(liveSessionIDs: next)
    }

    private static func liveSessionIDs(in registry: SessionRegistry) -> Set<String> {
        Set(registry.activeSessionIDByPanelID.values)
    }
}
