import Combine
import CoreState
import Foundation

/// The app owns local viewing demand. One window closing Peek cannot remove
/// another window's panel or the Coordinator from the conversation service.
@MainActor
final class CoordinatorPeekStore: ObservableObject {
    struct Inspection {
        let title: String
        let workspaceID: UUID?
        let panelID: UUID?
        let conversation: CoordinatorConversationModel?
        let unavailableReason: String?
        var taskID: UUID? = nil
        var expectedSessionID: String? = nil
    }

    @Published private(set) var inspections: [UUID: Inspection] = [:]
    private let service: ConversationService
    private let session: CoordinatorSessionController
    private let board: TaskBoardStore
    private let store: AppStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private var sessionSubscription: AnyCancellable?
    private var runtimeSubscription: AnyCancellable?
    private var boardSubscription: AnyCancellable?
    private var storeObserver: UUID?
    private var validationScheduled = false
    /// A hidden model can still own an unfinished draft or an uncertain send.
    /// Inspection.panelID is cleared on invalidation; it is not the cache key.
    private var modelsByPanelID: [UUID: CoordinatorConversationModel] = [:]
    private var modelSubscriptions: [UUID: AnyCancellable] = [:]

    private struct Target {
        let workspaceID: UUID
        let panelID: UUID
    }

    private enum Resolution {
        case terminal(Target)
        case unavailable(String)
    }

    init(service: ConversationService, session: CoordinatorSessionController, board: TaskBoardStore,
         store: AppStore, sessionRuntimeStore: SessionRuntimeStore) {
        self.service = service
        self.session = session
        self.board = board
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        sessionSubscription = session.objectWillChange.sink { [weak self] in
            self?.scheduleValidation()
        }
        storeObserver = store.addActionAppliedObserver { [weak self] _, _, next in
            guard let self else { return }
            let windows = Set(next.windows.map(\.id))
            let surviving = self.inspections.filter { windows.contains($0.key) }
            if surviving.count != self.inspections.count {
                self.inspections = surviving
                self.updateDemand()
            }
            // Panels and task workspaces can close while their native window
            // stays open, including terminals with no active runtime to publish.
            self.scheduleValidation()
        }
        runtimeSubscription = sessionRuntimeStore.$sessionRegistry.sink { [weak self] _ in
            self?.scheduleValidation()
        }
        boardSubscription = board.objectWillChange.sink { [weak self] _ in
            self?.scheduleValidation()
        }
        updateDemand()
    }

    deinit {
        if let storeObserver {
            let store = store
            Task { @MainActor in store.removeActionAppliedObserver(storeObserver) }
        }
    }

    func openTask(_ taskID: UUID, in windowID: UUID) {
        guard let item = board.items().first(where: { $0.taskID == taskID }), let record = item.record else {
            showUnavailable(title: "Task session", in: windowID, taskID: taskID,
                reason: "This task record is no longer available.")
            return
        }
        switch resolveTask(record) {
        case .terminal(let target): open(title: item.title, target: target, in: windowID, taskID: taskID)
        case .unavailable(let reason): showUnavailable(title: item.title, in: windowID, taskID: taskID, reason: reason)
        }
    }

    func openSession(_ sessionID: String, in windowID: UUID) {
        guard let record = sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID],
              sessionRuntimeStore.sessionRegistry.activeSession(for: record.panelID)?.sessionID == sessionID else {
            showUnavailable(title: "Session", in: windowID, expectedSessionID: sessionID,
                reason: "This session is no longer active. Open its task to inspect the current session.")
            return
        }
        open(title: record.displayTitleOverride ?? record.providerSessionName ?? "Task session",
             target: Target(workspaceID: record.workspaceID, panelID: record.panelID),
             in: windowID, expectedSessionID: sessionID)
    }

    func close(in windowID: UUID) {
        inspections.removeValue(forKey: windowID)
        updateDemand()
    }

    private func open(title: String, target: Target, in windowID: UUID,
                      taskID: UUID? = nil, expectedSessionID: String? = nil) {
        guard target.panelID != session.identity?.panelID else {
            showUnavailable(title: title, in: windowID, taskID: taskID, expectedSessionID: expectedSessionID,
                reason: "Coordinator is already shown in the main chat.")
            return
        }
        guard let location = terminalLocation(target.panelID) else {
            showUnavailable(title: title, in: windowID, taskID: taskID, expectedSessionID: expectedSessionID,
                reason: "This task terminal is closed.")
            return
        }
        let model = modelsByPanelID[target.panelID] ?? CoordinatorConversationModel(service: service, panelID: target.panelID)
        modelsByPanelID[target.panelID] = model
        if modelSubscriptions[target.panelID] == nil {
            modelSubscriptions[target.panelID] = Publishers.CombineLatest3(model.$draft, model.$attachments, model.$sending)
                .map { !$0.isEmpty || !$1.isEmpty || $2 }
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] _ in self?.scheduleValidation() }
        }
        inspections[windowID] = .init(title: title, workspaceID: location.workspaceID, panelID: location.panelID,
            conversation: model,
            unavailableReason: nil, taskID: taskID, expectedSessionID: expectedSessionID)
        updateDemand()
        model.refresh()
    }

    private func showUnavailable(title: String, in windowID: UUID, taskID: UUID? = nil,
                                 expectedSessionID: String? = nil, reason: String) {
        let previous = inspections[windowID]
        let sameTarget = (taskID != nil && previous?.taskID == taskID)
            || (expectedSessionID != nil && previous?.expectedSessionID == expectedSessionID)
        inspections[windowID] = .init(title: title, workspaceID: nil, panelID: nil,
            conversation: sameTarget ? previous?.conversation : nil, unavailableReason: reason,
            taskID: taskID, expectedSessionID: expectedSessionID)
        updateDemand()
    }

    private func scheduleValidation() {
        guard !validationScheduled else { return }
        validationScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.validationScheduled = false
            self.validateInspections()
        }
    }

    private func validateInspections() {
        var next = inspections
        var changed = false
        let items = Dictionary(board.items().compactMap { item in item.taskID.map { ($0, item) } },
                               uniquingKeysWith: { first, _ in first })
        for (windowID, inspection) in inspections {
            guard let panelID = inspection.panelID else { continue }
            var reason: String?
            var title = inspection.title
            let location = terminalLocation(panelID)
            if panelID == session.identity?.panelID {
                reason = "Coordinator is already shown in the main chat."
            } else if let expected = inspection.expectedSessionID,
               sessionRuntimeStore.sessionRegistry.activeSession(for: panelID)?.sessionID != expected {
                reason = "The selected session ended or was replaced. Open the task again to inspect its current agent."
            } else if let taskID = inspection.taskID {
                if let item = items[taskID], let record = item.record {
                    title = item.title
                    switch resolveTask(record) {
                    case .terminal(let current) where current.panelID != panelID:
                        reason = "The task agent moved to another terminal. Open Peek again to inspect it."
                    case .terminal: break
                    case .unavailable(let message): reason = message
                    }
                } else {
                    reason = "This task record is no longer available."
                }
            }
            if reason == nil, location == nil {
                reason = "This task terminal is closed."
            }
            if let reason {
                next[windowID] = Inspection(title: title, workspaceID: inspection.workspaceID,
                    panelID: nil, conversation: inspection.conversation, unavailableReason: reason,
                    taskID: inspection.taskID, expectedSessionID: inspection.expectedSessionID)
                changed = true
            } else if let location, location.workspaceID != inspection.workspaceID || title != inspection.title {
                next[windowID] = Inspection(title: title, workspaceID: location.workspaceID,
                    panelID: panelID, conversation: inspection.conversation, unavailableReason: nil,
                    taskID: inspection.taskID, expectedSessionID: inspection.expectedSessionID)
                changed = true
            }
        }
        if changed { inspections = next }
        updateDemand()
    }

    private func resolveTask(_ record: TaskRecord) -> Resolution {
        // This is the task.send resolver. In particular, native restore may
        // replace the saved managed ID while keeping the task's current panel.
        if let current = board.coordinator?.liveAgentSession(of: record) {
            return .terminal(Target(workspaceID: current.workspaceID, panelID: current.panelID))
        }
        var fallbacks: [(Target, String?)] = []
        if let moved = record.operation.worktreeSession {
            fallbacks.append((Target(workspaceID: moved.workspaceID, panelID: moved.panelID), moved.sessionID))
        }
        if let saved = record.currentSessionID.flatMap({ sessionRuntimeStore.sessionRegistry.sessionsByID[$0] }) {
            fallbacks.append((Target(workspaceID: saved.workspaceID, panelID: saved.panelID), saved.sessionID))
        }
        if let taskSpace = record.operation.taskSpace {
            fallbacks.append((Target(workspaceID: taskSpace.workspaceID, panelID: taskSpace.panelID), record.operation.agentLaunch?.sessionID))
        }
        for (target, expected) in fallbacks where terminalLocation(target.panelID) != nil {
            if let active = sessionRuntimeStore.sessionRegistry.activeSession(for: target.panelID), active.sessionID != expected {
                return .unavailable("The saved task terminal now holds a different session. Open the task again when its current session is available.")
            }
            return .terminal(target)
        }
        return .unavailable("This task has no available terminal.")
    }

    private func terminalLocation(_ panelID: UUID) -> Target? {
        guard let location = store.state.workspaceSelection(containingPanelID: panelID),
              case .terminal? = location.workspace.panelState(for: panelID) else { return nil }
        return Target(workspaceID: location.workspaceID, panelID: panelID)
    }

    private func updateDemand() {
        let displayed = Set(inspections.values.compactMap(\.conversation).map(ObjectIdentifier.init))
        modelsByPanelID = modelsByPanelID.filter { _, model in
            displayed.contains(ObjectIdentifier(model)) || !model.draft.isEmpty
                || !model.attachments.isEmpty || model.sending
        }
        modelSubscriptions = modelSubscriptions.filter { modelsByPanelID[$0.key] != nil }
        let visiblePanels = Self.panelDemand(coordinator: session.identity?.panelID,
            inspections: inspections.values.compactMap(\.panelID))
        let retainedPanels = Set(modelsByPanelID.compactMap { panelID, model in
            terminalLocation(panelID) != nil && (!model.draft.isEmpty || !model.attachments.isEmpty || model.sending)
                ? panelID : nil
        }).subtracting(visiblePanels)
        // Change both sets together. Dropping viewing demand first would destroy
        // the binding before retained observation can take ownership.
        service.setLocalPanelIDs(visiblePanels, retainingDraftPanels: retainedPanels)
    }

    static func panelDemand(coordinator: UUID?, inspections: [UUID]) -> Set<UUID> {
        Set(inspections + (coordinator.map { [$0] } ?? []))
    }
}
