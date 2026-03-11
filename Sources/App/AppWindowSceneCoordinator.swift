import CoreState
import Foundation

@MainActor
final class AppWindowSceneCoordinator {
    private var presentedWindowIDs: Set<UUID> = []
    private var pendingWindowIDs: Set<UUID> = []

    func registerPresentedWindow(windowID: UUID) {
        pendingWindowIDs.remove(windowID)
        presentedWindowIDs.insert(windowID)
    }

    func unregisterPresentedWindow(windowID: UUID) {
        pendingWindowIDs.remove(windowID)
        presentedWindowIDs.remove(windowID)
    }

    func reserveMissingWindowIDs(in state: AppState, excluding excludedWindowIDs: Set<UUID> = []) -> [UUID] {
        let desiredWindowIDs = Set(state.windows.map(\.id))
        pendingWindowIDs.formIntersection(desiredWindowIDs)

        let unavailableWindowIDs = presentedWindowIDs
            .union(pendingWindowIDs)
            .union(excludedWindowIDs)
        let missingWindowIDs = state.windows
            .map(\.id)
            .filter { unavailableWindowIDs.contains($0) == false }

        pendingWindowIDs.formUnion(missingWindowIDs)
        return missingWindowIDs
    }

    func claimWindowID(in state: AppState) -> UUID? {
        let desiredWindowIDs = state.windows.map(\.id)
        pendingWindowIDs.formIntersection(Set(desiredWindowIDs))

        if let pendingWindowID = desiredWindowIDs.first(where: {
            pendingWindowIDs.contains($0) && presentedWindowIDs.contains($0) == false
        }) {
            pendingWindowIDs.remove(pendingWindowID)
            presentedWindowIDs.insert(pendingWindowID)
            return pendingWindowID
        }

        if let availableWindowID = desiredWindowIDs.first(where: {
            pendingWindowIDs.contains($0) == false && presentedWindowIDs.contains($0) == false
        }) {
            presentedWindowIDs.insert(availableWindowID)
            return availableWindowID
        }

        return nil
    }
}
