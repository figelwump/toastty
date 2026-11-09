import CoreState
import Foundation

extension AppControlActionID {
    var isCoordinatorAction: Bool {
        switch self {
        case .coordinatorOpen, .coordinatorRestart, .coordinatorSend: true
        default: false
        }
    }
}

/// The coordinator's actions and query. They work on the one coordinator
/// that `CoordinatorController` owns.
extension AppControlExecutor {
    var coordinatorController: CoordinatorController? {
        taskCoordinator?.coordinatorController
    }

    private func requiredCoordinatorController() throws -> CoordinatorController {
        guard let coordinatorController else {
            throw AutomationSocketError.invalidPayload("the coordinator is not available in this Toastty instance")
        }
        return coordinatorController
    }

    /// A workspace-scoped session reaches the coordinator only when the
    /// coordinator's workspace is in its scope, and it cannot create one.
    /// The coordinator acts on every task, so text typed into it must come
    /// from a caller that could act on every task itself.
    private func enforceCoordinatorAccess() throws {
        if let workspaceID = try requiredStore().state.coordinatorWorkspaceID {
            try enforceWorkspaceAutomationAccess(workspaceID)
        } else if let callerSessionID = requestContext().callerSessionID, callerIsWorkspaceScoped(sessionID: callerSessionID) {
            throw AutomationSocketError.invalidPayload("a workspace-scoped session cannot create the coordinator")
        }
    }

    struct CoordinatorStartPreparation {
        let controller: CoordinatorController
        let windowID: UUID?
        let select: Bool
    }

    func prepareCoordinatorStart(
        _ action: AppControlActionID,
        args: [String: AutomationJSONValue]
    ) throws -> CoordinatorStartPreparation {
        let controller = try requiredCoordinatorController()
        try enforceCoordinatorAccess()
        // The window only matters while there is no coordinator to open.
        // Without one, the selected window gets the coordinator.
        var windowID: UUID?
        if let rawWindowID = args.coordinatorString("windowID") {
            guard let requested = UUID(uuidString: rawWindowID), try requiredStore().state.window(id: requested) != nil else {
                throw AutomationSocketError.invalidPayload("windowID does not exist")
            }
            windowID = requested
        }
        return CoordinatorStartPreparation(
            controller: controller,
            windowID: windowID,
            select: try optionalBooleanParameter("select", args: args, defaultValue: true)
        )
    }

    func finishCoordinatorStart(
        _ action: AppControlActionID,
        preparation: CoordinatorStartPreparation
    ) async throws -> AppControlActionOutcome {
        let controller = preparation.controller
        let result: CoordinatorController.StartResult
        do {
            if action == .coordinatorRestart {
                result = try await controller.restart(windowID: preparation.windowID)
            } else {
                result = try await controller.open(windowID: preparation.windowID, select: preparation.select)
            }
        } catch let error as CoordinatorError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
        var response = Self.coordinatorSnapshot(controller)
        response["createdWorkspace"] = .bool(result.createdWorkspace)
        response["startedAgent"] = .bool(result.startedAgent)
        return .init(didMutateState: true, result: response)
    }

    func runCoordinatorSend(args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        let controller = try requiredCoordinatorController()
        try enforceCoordinatorAccess()
        guard let text = args.coordinatorString("text") else {
            throw AutomationSocketError.invalidPayload("text is required")
        }
        let result: CoordinatorController.SendResult
        do {
            result = try controller.send(text)
        } catch let error as CoordinatorError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
        var response: [String: AutomationJSONValue] = ["queuedCount": .int(controller.queuedCount)]
        switch result {
        case .sent:
            response["delivery"] = .string("sent")
        case .sentUnconfirmed:
            response["delivery"] = .string("sentUnconfirmed")
        case .queued(let position, let hold):
            response["delivery"] = .string("queued")
            response["position"] = .int(position)
            response["hold"] = .string(hold.rawValue)
        }
        return .init(didMutateState: false, result: response)
    }

    func coordinatorQuery() throws -> [String: AutomationJSONValue] {
        let controller = try requiredCoordinatorController()
        try enforceCoordinatorAccess()
        return Self.coordinatorSnapshot(controller)
    }

    static func coordinatorSnapshot(_ controller: CoordinatorController) -> [String: AutomationJSONValue] {
        guard let status = controller.status else {
            return ["exists": .bool(false), "queuedCount": .int(0)]
        }
        var snapshot: [String: AutomationJSONValue] = [
            "exists": .bool(true),
            "windowID": .string(status.location.windowID.uuidString),
            "workspaceID": .string(status.location.workspaceID.uuidString),
            "agentState": .string(status.agentState.rawValue),
            "queuedCount": .int(status.queuedCount),
        ]
        if let panelID = status.location.panelID { snapshot["panelID"] = .string(panelID.uuidString) }
        if let session = status.session {
            snapshot["sessionID"] = .string(session.sessionID)
            snapshot["agent"] = .string(session.agent.rawValue)
            if let kind = session.status?.kind { snapshot["status"] = .string(kind.rawValue) }
        }
        if let startFailure = status.startFailure { snapshot["startFailure"] = .string(startFailure) }
        if let hold = status.hold { snapshot["hold"] = .string(hold.rawValue) }
        return snapshot
    }
}

private extension Dictionary where Key == String, Value == AutomationJSONValue {
    func coordinatorString(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }
}
