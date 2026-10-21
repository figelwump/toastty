import CoreState
import Foundation

extension AppControlActionID {
    var isTaskAction: Bool {
        switch self {
        case .taskCreate, .taskRetry, .taskDelete, .taskSetWorkspace, .taskStartWork: true
        default: false
        }
    }
}

extension AppControlQueryID {
    var isTaskQuery: Bool {
        switch self {
        case .taskGet, .taskList, .taskWorkspaceChoices: true
        default: false
        }
    }
}

extension AppControlExecutor {
    func runTaskAction(_ action: AppControlActionID, args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        let coordinator = try requiredTaskCoordinator()
        switch action {
        case .taskCreate:
            throw AutomationSocketError.invalidPayload("task.create copies files before it returns; send it through app_control.run_action")
        case .taskRetry:
            let record = try visibleTask(args: args, coordinator: coordinator)
            try perform { try coordinator.retry(taskID: record.id) }
            return .init(didMutateState: true, result: coordinator.records.record(id: record.id).map(Self.taskSnapshot))
        case .taskStartWork:
            let request = TaskStartWorkRequest(
                branchPrefix: args.taskString("branchPrefix"),
                base: args.taskString("base"),
                title: args.taskString("title"),
                slug: args.taskString("slug")
            )
            let record = try perform { try coordinator.startWork(request, caller: taskCaller()) }
            return .init(didMutateState: true, result: Self.taskSnapshot(record))
        case .taskDelete:
            let record = try visibleTask(args: args, coordinator: coordinator)
            try perform { try coordinator.delete(taskID: record.id) }
            return .init(didMutateState: true, result: ["taskID": .string(record.id.uuidString), "deleted": .bool(true)])
        case .taskSetWorkspace:
            // The choice is checked first: a scoped caller learns it may not
            // reopen a workspace before anything about the task.
            let choice = try taskWorkspaceChoice(args: args)
            let record = try visibleTask(args: args, coordinator: coordinator)
            try perform { try coordinator.setWorkspace(taskID: record.id, choice: choice) }
            return .init(didMutateState: true, result: coordinator.records.record(id: record.id).map(Self.taskSnapshot))
        default:
            throw AutomationSocketError.invalidPayload("unsupported task action: \(action.rawValue)")
        }
    }

    /// The checks run now, in this request's context; the files are copied
    /// after an await, off the main thread.
    func prepareTaskCreate(args: [String: AutomationJSONValue]) throws -> (TaskCoordinator, TaskCreatePreparation) {
        let coordinator = try requiredTaskCoordinator()
        let preparation = try perform { try coordinator.prepareCreate(try taskCreateRequest(args: args), caller: taskCaller()) }
        return (coordinator, preparation)
    }

    func finishTaskCreate(_ coordinator: TaskCoordinator, _ preparation: TaskCreatePreparation) async throws -> AppControlActionOutcome {
        do {
            let record = try await coordinator.finishCreate(preparation)
            return .init(didMutateState: true, result: Self.taskSnapshot(record))
        } catch let error as TaskError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
    }

    func runTaskQuery(_ query: AppControlQueryID, args: [String: AutomationJSONValue]) throws -> [String: AutomationJSONValue] {
        let coordinator = try requiredTaskCoordinator()
        switch query {
        case .taskGet:
            return Self.taskSnapshot(try visibleTask(args: args, coordinator: coordinator))
        case .taskList:
            let tasks = coordinator.records.records.filter(callerMaySee).map { AutomationJSONValue.object(Self.taskSnapshot($0)) }
            return ["tasks": .array(tasks)]
        case .taskWorkspaceChoices:
            return workspaceChoicesSnapshot(coordinator.workspaceChoices())
        default:
            throw AutomationSocketError.invalidPayload("unsupported task query: \(query.rawValue)")
        }
    }

    private func requiredTaskCoordinator() throws -> TaskCoordinator {
        guard let taskCoordinator else {
            throw AutomationSocketError.invalidPayload("tasks are not available in this Toastty instance")
        }
        return taskCoordinator
    }

    private func perform<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as TaskError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
    }

    /// The caller, read now: setup runs later, after this request context
    /// is gone.
    private func taskCaller() -> TaskCaller {
        guard let session = callerManagedSession() else { return .unmanaged }
        return TaskCaller(sessionID: session.sessionID, workspaceID: session.workspaceID)
    }

    private func taskCreateRequest(args: [String: AutomationJSONValue]) throws -> TaskCreateRequest {
        var workspaceID: UUID?
        if let raw = args.taskString("workspace") {
            guard let parsed = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
                throw AutomationSocketError.invalidPayload("workspace must be a workspace ID")
            }
            workspaceID = parsed
        }
        // A scoped agent may always add tasks to its own project. Any other
        // workspace must be in its scope, and so must that workspace's root,
        // where the task space is made, as `workspace.create` requires.
        if let workspaceID {
            let parentIDs = try requiredStore().state.subspaceParentIDsByWorkspaceID()
            let callerRoot = callerManagedSession().map { parentIDs[$0.workspaceID] ?? $0.workspaceID }
            let requestedRoot = parentIDs[workspaceID] ?? workspaceID
            if requestedRoot != callerRoot {
                try enforceWorkspaceAutomationAccess(workspaceID)
                try enforceWorkspaceAutomationAccess(requestedRoot)
            }
        }
        return TaskCreateRequest(
            text: args.taskString("text") ?? "",
            files: try Self.taskStrings("files", args: args),
            clientRequestID: args.taskString("clientRequestID"),
            title: args.taskString("title"),
            slug: args.taskString("slug"),
            workspaceID: workspaceID,
            agent: args.taskString("agent"),
            model: args.taskString("model"),
            effort: args.taskString("effort"),
            prompt: args.taskString("prompt"),
            startWork: try args.taskBool("startWork") ?? false,
            base: args.taskString("base"),
            branchPrefix: args.taskString("branchPrefix")
        )
    }

    /// A scoped session may place a task only in a workspace in its scope,
    /// and may not reopen a closed one: that makes a new top-level
    /// workspace, which no scope covers.
    private func taskWorkspaceChoice(args: [String: AutomationJSONValue]) throws -> TaskWorkspaceChoice {
        let workspace = args.taskString("workspace")
        let recent = args.taskString("recentWorkspace")
        switch (workspace, recent) {
        case (let raw?, nil):
            guard let workspaceID = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
                throw AutomationSocketError.invalidPayload("workspace must be a workspace ID")
            }
            let parentIDs = try requiredStore().state.subspaceParentIDsByWorkspaceID()
            try enforceWorkspaceAutomationAccess(workspaceID)
            try enforceWorkspaceAutomationAccess(parentIDs[workspaceID] ?? workspaceID)
            return .open(workspaceID)
        case (nil, let raw?):
            guard let recentID = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
                throw AutomationSocketError.invalidPayload("recentWorkspace must be an ID from task.workspace-choices")
            }
            if let callerSessionID = requestContext().callerSessionID, callerIsWorkspaceScoped(sessionID: callerSessionID) {
                throw AutomationSocketError.invalidPayload("a workspace-scoped session cannot reopen a closed workspace")
            }
            return .recent(recentID)
        default:
            throw AutomationSocketError.invalidPayload("pass either workspace or recentWorkspace")
        }
    }

    private func workspaceChoicesSnapshot(_ choices: TaskWorkspaceChoices) -> [String: AutomationJSONValue] {
        let isScoped = requestContext().callerSessionID.map(callerIsWorkspaceScoped(sessionID:)) ?? false
        let open = choices.open.filter { callerMayAutomateWorkspace($0.id) }.map { workspace -> AutomationJSONValue in
            .object(["workspaceID": .string(workspace.id.uuidString), "title": .string(workspace.title)])
        }
        let recent = isScoped ? [] : choices.recent.map { item -> AutomationJSONValue in
            .object([
                "recentWorkspace": .string(item.id.uuidString),
                "title": .string(item.title),
                "rootDirectory": .string(item.rootDirectory),
                "closedAt": .string(ISO8601DateFormatter().string(from: item.closedAt)),
            ])
        }
        return ["open": .array(open), "recent": .array(recent)]
    }

    private func visibleTask(args: [String: AutomationJSONValue], coordinator: TaskCoordinator) throws -> TaskRecord {
        guard let raw = args.taskString("taskID"), let taskID = UUID(uuidString: raw) else {
            throw AutomationSocketError.invalidPayload("taskID must be a task ID")
        }
        guard let record = coordinator.records.record(id: taskID), callerMaySee(record) else {
            throw AutomationSocketError.invalidPayload("No task has ID \(taskID.uuidString).")
        }
        return record
    }

    /// An unscoped caller sees every task. A workspace-scoped session sees
    /// the tasks it created and those whose workspace or task space is in
    /// its scope.
    private func callerMaySee(_ record: TaskRecord) -> Bool {
        guard let callerSessionID = requestContext().callerSessionID,
              callerIsWorkspaceScoped(sessionID: callerSessionID) else {
            return true
        }
        if case .agent(let creatorSessionID) = record.source, creatorSessionID == callerSessionID {
            return true
        }
        return [record.workspaceID, record.taskSpaceWorkspaceID]
            .compactMap { $0 }
            .contains { callerMayAutomateWorkspace($0) }
    }

    private static func taskStrings(_ key: String, args: [String: AutomationJSONValue]) throws -> [String] {
        switch args[key] {
        case nil:
            return []
        case .string(let value)?:
            return [value]
        case .array(let values)?:
            return try values.map { value in
                guard case .string(let string) = value else {
                    throw AutomationSocketError.invalidPayload("\(key) must be strings")
                }
                return string
            }
        default:
            throw AutomationSocketError.invalidPayload("\(key) must be a string or a list of strings")
        }
    }

    static func taskSnapshot(_ record: TaskRecord) -> [String: AutomationJSONValue] {
        func optional(_ value: String?) -> AutomationJSONValue { value.map(AutomationJSONValue.string) ?? .null }
        var setup: [String: AutomationJSONValue]
        switch record.setup {
        case .routing:
            setup = ["state": .string("routing")]
        case .needsWorkspace(let reason):
            setup = ["state": .string("needsWorkspace"), "reason": .string(reason)]
        case .settingUp:
            setup = ["state": .string("settingUp")]
        case .setupFailed(let reason):
            setup = ["state": .string("setupFailed"), "reason": .string(reason)]
        case .started:
            setup = ["state": .string("started")]
        }
        setup["taskSpaceWorkspaceID"] = optional(record.taskSpaceWorkspaceID?.uuidString)
        setup["sessionID"] = optional(record.operation.agentLaunch?.sessionID)
        let source: String
        switch record.source {
        case .cli: source = "cli"
        case .agent: source = "agent"
        case .recovered: source = "recovered"
        }
        var snapshot: [String: AutomationJSONValue] = [
            "taskID": .string(record.id.uuidString),
            "parentTaskID": optional(record.parentTaskID?.uuidString),
            "title": .string(record.title),
            "slug": .string(record.slug),
            "text": .string(record.text),
            "createdAt": .string(ISO8601DateFormatter().string(from: record.createdAt)),
            "source": .string(source),
            "clientRequestID": optional(record.clientRequestID),
            "workspaceID": optional(record.workspaceID?.uuidString),
            "projectRoot": optional(record.projectRoot),
            "agent": optional(record.resolved?.agent),
            "model": optional(record.resolved?.model),
            "effort": optional(record.resolved?.effort),
            "prompt": optional(record.resolved?.prompt),
            "triageNote": optional(record.triageNote),
            "files": .array(record.attachments.map { .string($0.path) }),
            "setup": .object(setup),
            "sessionID": optional(record.currentSessionID),
        ]
        if let startWork = record.startWork {
            snapshot["worktree"] = .object(worktreeSnapshot(record, startWork: startWork))
        }
        return snapshot
    }

    /// The `worktree` object: the move's state, and what it made so far.
    private static func worktreeSnapshot(_ record: TaskRecord, startWork: TaskStartWork) -> [String: AutomationJSONValue] {
        func optional(_ value: String?) -> AutomationJSONValue { value.map(AutomationJSONValue.string) ?? .null }
        let operation = record.operation
        var result: [String: AutomationJSONValue] = [
            "branchPrefix": .string(startWork.branchPrefix),
            "requestedBase": optional(startWork.base),
            "path": optional(record.worktree?.path),
            "branch": optional(record.worktree?.branch),
            "baseSHA": optional(operation.base?.sha),
            "baseRef": optional(operation.base?.ref),
            "baseFetched": operation.base.map { .bool($0.fetched) } ?? .null,
            "baseNote": optional(operation.base?.note),
            "sessionID": optional(operation.worktreeSession?.sessionID),
            "forked": operation.worktreeSession.map { .bool($0.forked) } ?? .null,
            "conversationConfirmed": .bool(operation.worktreeSession?.nativeConversationID != nil),
            "sourceSessionID": optional(startWork.source?.sessionID),
        ]
        switch startWork.state {
        case .running:
            result["state"] = .string("running")
        case .failed(let reason):
            result["state"] = .string("failed")
            result["reason"] = .string(reason)
        case .finished:
            result["state"] = .string("finished")
        }
        switch operation.sourceOutcome {
        case nil:
            result["source"] = .null
        case .closed?:
            result["source"] = .string("closed")
        case .exited?:
            result["source"] = .string("exited")
        case .kept(let reason)?:
            result["source"] = .string("kept")
            result["sourceKeptReason"] = .string(reason)
        }
        return result
    }
}

private extension Dictionary where Key == String, Value == AutomationJSONValue {
    func taskString(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }

    func taskBool(_ key: String) throws -> Bool? {
        switch self[key] {
        case nil, .null?:
            return nil
        case .bool(let value)?:
            return value
        case .string(let value)? where value == "true" || value == "false":
            return value == "true"
        default:
            throw AutomationSocketError.invalidPayload("\(key) must be true or false")
        }
    }
}
