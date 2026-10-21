import CoreState
import Foundation

extension AppControlActionID {
    var isTaskAction: Bool {
        switch self {
        case .taskCreate, .taskRetry, .taskDelete, .taskSetWorkspace, .taskStartWork, .taskSend, .taskWatch, .taskUnwatch,
             .taskMerge, .taskCancelMerge, .taskCleanUp, .taskReadyForReview, .taskMarkDone, .taskArchive, .taskRelease,
             .taskAdopt, .windowTasksShow, .windowTasksHide, .windowSidebarSetSegment: true
        default: false
        }
    }
}

extension AppControlQueryID {
    var isTaskQuery: Bool {
        switch self {
        case .taskGet, .taskList, .taskWorkspaceChoices, .taskWatches: true
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
            return .init(didMutateState: true, result: coordinator.records.record(id: record.id).map { Self.taskSnapshot($0) })
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
            return .init(didMutateState: true, result: coordinator.records.record(id: record.id).map { Self.taskSnapshot($0) })
        case .taskMerge:
            let record = try ownOrVisibleTask(args: args, coordinator: coordinator)
            let merged = try perform {
                try coordinator.merge(taskID: record.id, expectedHead: args.taskString("head"), caller: taskCaller())
            }
            return .init(didMutateState: true, result: Self.taskSnapshot(merged))
        case .taskCancelMerge:
            let record = try ownOrVisibleTask(args: args, coordinator: coordinator)
            try perform { try coordinator.cancelMerge(taskID: record.id) }
            return .init(didMutateState: true, result: coordinator.records.record(id: record.id).map { Self.taskSnapshot($0) })
        case .taskCleanUp:
            let record = try visibleTask(args: args, coordinator: coordinator)
            try perform { try coordinator.retryCleanup(taskID: record.id) }
            return .init(didMutateState: true, result: coordinator.records.record(id: record.id).map { Self.taskSnapshot($0) })
        case .taskReadyForReview:
            let record = try ownOrVisibleTask(args: args, coordinator: coordinator)
            let updated = try perform { try coordinator.readyForReview(taskID: record.id) }
            return .init(didMutateState: true, result: Self.taskSnapshot(updated))
        case .taskMarkDone:
            let record = try visibleTask(args: args, coordinator: coordinator)
            let updated = try perform { try coordinator.markDone(taskID: record.id) }
            return .init(didMutateState: true, result: Self.taskSnapshot(updated))
        case .taskArchive:
            throw AutomationSocketError.invalidPayload("task.archive checks git before it returns; send it through app_control.run_action")
        case .taskSend:
            let record = try visibleTask(args: args, coordinator: coordinator)
            guard let text = args.taskString("text") else {
                throw AutomationSocketError.invalidPayload("text is required")
            }
            let session = try perform { try coordinator.send(taskID: record.id, text: text) }
            return .init(didMutateState: false, result: [
                "taskID": .string(record.id.uuidString),
                "sessionID": .string(session.sessionID),
                "panelID": .string(session.panelID.uuidString),
                "delivered": .bool(true),
            ])
        case .taskWatch:
            let target = try visibleTask(args: args, coordinator: coordinator)
            guard let rawCondition = args.taskString("until"), let condition = TaskWatchCondition(rawValue: rawCondition) else {
                throw AutomationSocketError.invalidPayload(
                    "until must be one of: \(TaskWatchCondition.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            let wait = try args.taskBool("wait") ?? false
            var notifyTaskID: UUID?
            if let raw = args.taskString("notifyTaskID") {
                guard wait == false else {
                    throw AutomationSocketError.invalidPayload("pass notifyTaskID or wait=true, not both")
                }
                notifyTaskID = try visibleTask(args: ["taskID": .string(raw)], coordinator: coordinator).id
            } else if wait == false {
                guard let own = coordinator.task(inWorkspace: callerManagedSession()?.workspaceID) else {
                    throw AutomationSocketError.invalidPayload(
                        "the caller is not a task's agent; name the task to notify with notifyTaskID, or pass wait=true and poll task.watches"
                    )
                }
                notifyTaskID = own.id
            }
            let watch = try perform {
                try coordinator.addWatch(targetTaskID: target.id, condition: condition, notifyTaskID: notifyTaskID)
            }
            return .init(didMutateState: true, result: Self.watchSnapshot(watch, notifyTaskID: notifyTaskID))
        case .taskUnwatch:
            guard let raw = args.taskString("watchID"), let watchID = UUID(uuidString: raw) else {
                throw AutomationSocketError.invalidPayload("watchID must be a watch ID")
            }
            guard let found = coordinator.watch(id: watchID), watchIsVisible(found, coordinator: coordinator) else {
                throw AutomationSocketError.invalidPayload("No watch has ID \(watchID.uuidString).")
            }
            try perform { try coordinator.cancelWatch(id: watchID) }
            return .init(didMutateState: true, result: ["watchID": .string(watchID.uuidString), "cancelled": .bool(true)])
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

    /// The checks that need only the request's context; the git checks run
    /// after an await.
    func prepareTaskArchive(args: [String: AutomationJSONValue]) throws -> (TaskCoordinator, UUID, TaskArchiveOptions) {
        let coordinator = try requiredTaskCoordinator()
        let record = try visibleTask(args: args, coordinator: coordinator)
        let options = TaskArchiveOptions(
            closePullRequest: try args.taskBool("closePullRequest") ?? false,
            deleteUnpushedCommits: try args.taskBool("deleteUnpushedCommits") ?? false,
            discardChanges: try args.taskBool("discardChanges") ?? false
        )
        return (coordinator, record.id, options)
    }

    func finishTaskArchive(_ coordinator: TaskCoordinator, taskID: UUID, options: TaskArchiveOptions) async throws -> AppControlActionOutcome {
        do {
            let record = try await coordinator.archive(taskID: taskID, options: options)
            return .init(didMutateState: true, result: Self.taskSnapshot(record))
        } catch let error as TaskError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
    }

    /// `task.release`, once the caller's access to the workspace is checked.
    func runTaskRelease(workspaceID: UUID) throws -> AppControlActionOutcome {
        let coordinator = try requiredTaskCoordinator()
        let parentIDs = try requiredStore().state.subspaceParentIDsByWorkspaceID()
        try enforceWorkspaceAutomationAccess(parentIDs[workspaceID] ?? workspaceID)
        let record = try perform { try coordinator.release(workspaceID: workspaceID, caller: taskCaller()) }
        return .init(didMutateState: true, result: Self.taskSnapshot(record))
    }

    /// The named task, or without a taskID the calling agent's own task.
    private func ownOrVisibleTask(args: [String: AutomationJSONValue], coordinator: TaskCoordinator) throws -> TaskRecord {
        if args.taskString("taskID") == nil {
            guard let own = coordinator.task(inWorkspace: callerManagedSession()?.workspaceID) else {
                throw AutomationSocketError.invalidPayload("taskID is required outside a task's agent session")
            }
            return own
        }
        return try visibleTask(args: args, coordinator: coordinator)
    }

    /// `task.adopt`, once the caller's access to the workspace is checked.
    func runTaskAdopt(workspaceID: UUID) throws -> AppControlActionOutcome {
        let coordinator = try requiredTaskCoordinator()
        let record = try perform { try coordinator.adopt(workspaceID: workspaceID) }
        return .init(didMutateState: true, result: Self.taskSnapshot(record, stage: Self.stagesByTaskID(coordinator.board)[record.id]))
    }

    func runTaskQuery(_ query: AppControlQueryID, args: [String: AutomationJSONValue]) throws -> [String: AutomationJSONValue] {
        let coordinator = try requiredTaskCoordinator()
        switch query {
        case .taskGet:
            // Without a taskID, a task's agent reads its own task.
            let record: TaskRecord
            if args.taskString("taskID") == nil {
                guard let own = coordinator.task(inWorkspace: callerManagedSession()?.workspaceID) else {
                    throw AutomationSocketError.invalidPayload("taskID is required outside a task's agent session")
                }
                record = own
            } else {
                record = try visibleTask(args: args, coordinator: coordinator)
            }
            return liveTaskSnapshot(
                record, coordinator: coordinator, stage: Self.stagesByTaskID(coordinator.board)[record.id], includeReply: true
            )
        case .taskList:
            let includeReply = try args.taskBool("includeReply") ?? false
            let stages = Self.stagesByTaskID(coordinator.board)
            // Every task's snapshot goes to the change feed, so one caller's
            // poll never hides a change from another. The reply is left out
            // of what the feed compares: it changes only with agentState.
            let records = coordinator.records.records
            let snapshots = Dictionary(uniqueKeysWithValues: records.map {
                ($0.id, liveTaskSnapshot($0, coordinator: coordinator, stage: stages[$0.id], includeReply: false))
            })
            let entries = Dictionary(uniqueKeysWithValues: records.map { record in
                (record.id, TaskChangeFeed.Entry(snapshot: .object(snapshots[record.id] ?? [:]), visibility: Self.visibility(of: record)))
            })
            let changes = coordinator.changeFeed.observe(entries, since: args.taskString("changedSince"))
            let parent = try args.taskString("parent").map { raw -> UUID in
                guard let id = UUID(uuidString: raw) else { throw AutomationSocketError.invalidPayload("parent must be a task ID") }
                return id
            }
            let listed = records.filter { record in
                callerMaySee(record)
                    && (args.taskString("changedSince") == nil || changes.changedTaskIDs.contains(record.id))
                    && (parent == nil || record.parentTaskID == parent)
            }
            let tasks = listed.map { record -> AutomationJSONValue in
                guard includeReply else { return .object(snapshots[record.id] ?? [:]) }
                return .object(liveTaskSnapshot(record, coordinator: coordinator, stage: stages[record.id], includeReply: true))
            }
            return [
                "tasks": .array(tasks),
                "cursor": .string(changes.cursor),
                "deletedTaskIDs": .array(changes.deletedTasks.filter { callerMaySee($0.visibility) }.map { .string($0.id.uuidString) }),
                "reset": .bool(args.taskString("changedSince") != nil && changes.reset),
            ]
        case .taskWorkspaceChoices:
            return workspaceChoicesSnapshot(coordinator.workspaceChoices())
        case .taskWatches:
            let watchID = try args.taskString("watchID").map { raw -> UUID in
                guard let id = UUID(uuidString: raw) else { throw AutomationSocketError.invalidPayload("watchID must be a watch ID") }
                return id
            }
            let targetID = try args.taskString("taskID").map { raw -> UUID in
                guard let id = UUID(uuidString: raw) else { throw AutomationSocketError.invalidPayload("taskID must be a task ID") }
                return id
            }
            let notifyID = try args.taskString("notifyTaskID").map { raw -> UUID in
                guard let id = UUID(uuidString: raw) else { throw AutomationSocketError.invalidPayload("notifyTaskID must be a task ID") }
                return id
            }
            if let watchID { coordinator.noteWaitWatchRead(id: watchID) }
            let watches = coordinator.allWatches().filter { entry in
                (watchID == nil || entry.watch.id == watchID)
                    && (targetID == nil || entry.watch.targetTaskID == targetID)
                    && (notifyID == nil || entry.notifyTaskID == notifyID)
                    && watchIsVisible(entry, coordinator: coordinator)
            }
            return ["watches": .array(watches.map { .object(Self.watchSnapshot($0.watch, notifyTaskID: $0.notifyTaskID)) })]
        default:
            throw AutomationSocketError.invalidPayload("unsupported task query: \(query.rawValue)")
        }
    }

    /// The record snapshot plus what only the running app knows: the agent's
    /// state and, when asked, its last reply.
    private func liveTaskSnapshot(
        _ record: TaskRecord,
        coordinator: TaskCoordinator,
        stage: TaskStage?,
        includeReply: Bool
    ) -> [String: AutomationJSONValue] {
        var snapshot = Self.taskSnapshot(record, stage: stage)
        snapshot["merge"] = coordinator.board?.mergeActivity(taskID: record.id).map { .string("\($0)") } ?? .null
        let status = coordinator.agentStatus(of: record)
        func optional(_ value: String?) -> AutomationJSONValue { value.map(AutomationJSONValue.string) ?? .null }
        snapshot["agentState"] = .object([
            "state": .string(status.activity.rawValue),
            "sessionID": optional(status.session?.sessionID),
            "panelID": optional(status.session?.panelID.uuidString),
            "summary": optional(status.session?.status?.summary),
            "changedAt": optional(status.changedAt.map { ISO8601DateFormatter().string(from: $0) }),
            "lastTurnEndedAt": optional(status.session?.lastTurnEndedAt.map { ISO8601DateFormatter().string(from: $0) }),
        ])
        if includeReply {
            snapshot["lastReply"] = coordinator.lastReply(of: record).map { reply in
                .object([
                    "text": .string(reply.text),
                    "truncated": .bool(reply.truncated),
                    "at": optional(reply.at.map { ISO8601DateFormatter().string(from: $0) }),
                ])
            } ?? .null
        }
        return snapshot
    }

    /// A watch is visible when the caller may see the task it notifies, or,
    /// for a `--wait` watch, the task it watches.
    private func watchIsVisible(_ entry: (watch: TaskWatch, notifyTaskID: UUID?), coordinator: TaskCoordinator) -> Bool {
        let ownerID = entry.notifyTaskID ?? entry.watch.targetTaskID
        guard let owner = coordinator.records.record(id: ownerID) else {
            // The watched task of a --wait watch was deleted.
            return requestContext().callerSessionID.map(callerIsWorkspaceScoped(sessionID:)) != true
        }
        return callerMaySee(owner)
    }

    static func watchSnapshot(_ watch: TaskWatch, notifyTaskID: UUID?) -> [String: AutomationJSONValue] {
        var result: [String: AutomationJSONValue] = [
            "watchID": .string(watch.id.uuidString),
            "taskID": .string(watch.targetTaskID.uuidString),
            "until": .string(watch.condition.rawValue),
            "notifyTaskID": notifyTaskID.map { .string($0.uuidString) } ?? .null,
            "createdAt": .string(ISO8601DateFormatter().string(from: watch.createdAt)),
        ]
        switch watch.state {
        case .pending:
            result["state"] = .string("pending")
        case .fired(let at, let reason, let impossible, let delivered):
            result["state"] = .string(impossible ? "impossible" : "fired")
            result["firedAt"] = .string(ISO8601DateFormatter().string(from: at))
            result["reason"] = .string(reason)
            result["delivered"] = .bool(delivered)
        }
        return result
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
        callerMaySee(Self.visibility(of: record))
    }

    private func callerMaySee(_ visibility: TaskChangeFeed.Visibility) -> Bool {
        guard let callerSessionID = requestContext().callerSessionID,
              callerIsWorkspaceScoped(sessionID: callerSessionID) else {
            return true
        }
        if visibility.creatorSessionID == callerSessionID {
            return true
        }
        return visibility.workspaceIDs.contains { callerMayAutomateWorkspace($0) }
    }

    private static func visibility(of record: TaskRecord) -> TaskChangeFeed.Visibility {
        var creator: String?
        if case .agent(let sessionID) = record.source { creator = sessionID }
        return .init(workspaceIDs: [record.workspaceID, record.taskSpaceWorkspaceID].compactMap { $0 }, creatorSessionID: creator)
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

    private static func stagesByTaskID(_ board: TaskBoardStore?) -> [UUID: TaskStage] {
        guard let board else { return [:] }
        return Dictionary(board.items().compactMap { item in item.taskID.map { ($0, item.stage) } }, uniquingKeysWith: { first, _ in first })
    }

    /// `stage` as `{group, attention?, reason?}`: the group the Tasks view
    /// lists the task in, and why it needs the user.
    static func stageSnapshot(_ stage: TaskStage) -> [String: AutomationJSONValue] {
        var result: [String: AutomationJSONValue] = ["group": .string("\(stage.group)"), "needsUser": .bool(stage.needsUser)]
        if case .needsYou(let attention) = stage {
            switch attention {
            case .pickWorkspace(let reason):
                result["attention"] = .string("pickWorkspace")
                result["reason"] = .string(reason)
            case .setupFailed(let reason):
                result["attention"] = .string("setupFailed")
                result["reason"] = .string(reason)
            case .moveFailed(let reason):
                result["attention"] = .string("moveFailed")
                result["reason"] = .string(reason)
            case .taskSpaceClosed: result["attention"] = .string("taskSpaceClosed")
            case .agentNeedsInput: result["attention"] = .string("agentNeedsInput")
            case .agentError: result["attention"] = .string("agentError")
            case .review: result["attention"] = .string("review")
            case .readyForReview: result["attention"] = .string("readyForReview")
            case .cleanupStopped(let reason):
                result["attention"] = .string("cleanupStopped")
                result["reason"] = .string(reason)
            }
        }
        return result
    }

    static func taskSnapshot(_ record: TaskRecord, stage: TaskStage? = nil) -> [String: AutomationJSONValue] {
        func optional(_ value: String?) -> AutomationJSONValue { value.map(AutomationJSONValue.string) ?? .null }
        func date(_ value: Date?) -> AutomationJSONValue { optional(value.map { ISO8601DateFormatter().string(from: $0) }) }
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
        case .quickEntry: source = "quickEntry"
        case .recovered: source = "recovered"
        case .adopted: source = "adopted"
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
            "pullRequestURL": optional(record.pullRequestURL),
            "mergedAt": date(record.mergedAt),
            "mergeCommit": optional(record.mergeCommit),
            "readyForReviewAt": date(record.readyForReviewAt),
            "mergeRequestedAt": date(record.mergeRequestedAt),
            "mergeCancelledAt": date(record.mergeCancelledAt),
            "shippedAt": date(record.shippedAt),
            "releaseTag": optional(record.releaseTag),
            "doneAt": date(record.doneAt),
            "archivedAt": date(record.archivedAt),
        ]
        if let cleanup = record.cleanup {
            snapshot["cleanup"] = .object([
                "kind": .string(cleanup.kind.rawValue),
                "stepsDone": .array(cleanup.stepsDone.map(AutomationJSONValue.string)),
                "problem": optional(cleanup.problem),
                "finishedAt": date(cleanup.finishedAt),
            ])
        }
        if let release = record.release {
            snapshot["release"] = .object([
                "childTaskIDs": .array(release.childTaskIDs.map { .string($0.uuidString) }),
            ])
        }
        if let stage {
            snapshot["stage"] = .object(stageSnapshot(stage))
        }
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
            "branch": optional(record.worktree.flatMap { $0.isDetached ? nil : $0.branch }),
            "detached": .bool(record.worktree?.isDetached ?? false),
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
