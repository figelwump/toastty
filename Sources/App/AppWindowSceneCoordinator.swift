import CoreState
import Foundation

@MainActor
final class AppWindowSceneCoordinator {
    private var presentedWindowIDs: Set<UUID> = []
    private var pendingWindowIDs: Set<UUID> = []
    private var dismissalRequestWindowIDs: Set<UUID> = []
    private var closeWindowHandlers: [UUID: @MainActor () -> Void] = [:]

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

    func dismissScene(windowID: UUID) -> Bool {
        guard let closeWindow = closeWindowHandlers[windowID] else { return false }
        closeWindow()
        return true
    }

    func requestSceneDismissalAfterBindingLoss(windowID: UUID) {
        dismissalRequestWindowIDs.insert(windowID)
    }

    func cancelSceneDismissalAfterBindingLoss(windowID: UUID) {
        dismissalRequestWindowIDs.remove(windowID)
    }

    func consumeSceneDismissalAfterBindingLoss(windowID: UUID) -> Bool {
        dismissalRequestWindowIDs.remove(windowID) != nil
    }

    func registerWindowCloseHandler(windowID: UUID, closeWindow: @escaping @MainActor () -> Void) {
        closeWindowHandlers[windowID] = closeWindow
    }

    func unregisterWindowCloseHandler(windowID: UUID) {
        closeWindowHandlers.removeValue(forKey: windowID)
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
