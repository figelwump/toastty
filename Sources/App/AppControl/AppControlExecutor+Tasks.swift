import CoreState
import Foundation
import RemoteProtocol

extension AppControlActionID {
    var isTaskAction: Bool {
        switch self {
        case .taskCreate, .taskRetry, .taskRecoverFable, .taskDelete, .taskSetWorkspace, .taskSetRelease, .taskStartWork, .taskSend, .taskWatch, .taskUnwatch,
             .taskMerge, .taskRequestMerge, .taskCancelMerge, .taskCleanUp, .taskReadyForReview, .taskNeedsReply, .taskAnswer, .taskWaiting,
             .taskMarkDone, .taskArchive, .taskRelease, .taskReleaseComplete, .taskAdopt, .windowTasksShow, .windowTasksHide, .windowSidebarSetSegment,
             .webhookAdd, .webhookSet, .webhookRemove, .webhookTest: true
        default: false
        }
    }
}

extension AppControlQueryID {
    var isTaskQuery: Bool {
        switch self {
        case .taskGet, .taskList, .taskWorkspaceChoices, .taskWatches, .webhookList: true
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
        case .taskRecoverFable:
            guard messageSender() == .coordinator else {
                throw AutomationSocketError.invalidPayload("Only the coordinator can request a Fable quota recovery.")
            }
            let record = try visibleTask(args: args, coordinator: coordinator)
            guard let sessionID = args.taskString("expectedSessionID") else {
                throw AutomationSocketError.invalidPayload("expectedSessionID is required")
            }
            try perform { try coordinator.recoverFableTask(taskID: record.id, expectedSessionID: sessionID) }
            return .init(didMutateState: true, result: [
                "taskID": .string(record.id.uuidString),
                "recovering": .bool(true),
            ])
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
        case .taskSetRelease:
            guard let afterMerge = try args.taskBool("afterMerge") else {
                throw AutomationSocketError.invalidPayload("afterMerge is required: true to release right after the merge, false to clear the request")
            }
            let record = try ownOrVisibleTask(args: args, coordinator: coordinator)
            let updated = try perform { try coordinator.setReleaseAfterMerge(taskID: record.id, requested: afterMerge) }
            return .init(didMutateState: true, result: Self.taskSnapshot(updated))
        case .taskMerge:
            throw AutomationSocketError.invalidPayload("task.merge waits for the merge's first answer; send it through app_control.run_action")
        case .taskRequestMerge:
            let record = try visibleTask(args: args, coordinator: coordinator)
            try perform { try coordinator.requestMergeFromOutside(taskID: record.id) }
            return .init(didMutateState: true, result: coordinator.records.record(id: record.id).map { Self.taskSnapshot($0) })
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
        case .taskNeedsReply:
            let record = try ownOrVisibleTask(args: args, coordinator: coordinator)
            let version = args.taskString("fleetVersion")
            let targets = args.taskString("fleetTargets")
            let approval = try args.taskBool("approval") == true || version != nil || targets != nil
            let fleetChecks: TaskFleetChecks?
            if version != nil || targets != nil {
                guard let version, let targets, args["question"] == nil,
                      let scope = TaskFleetChecks(version: version, targets: targets.components(separatedBy: ",")) else {
                    throw AutomationSocketError.invalidPayload("Supply a website version and comma-separated fleet target IDs without a custom question.")
                }
                fleetChecks = scope
            } else {
                fleetChecks = nil
            }
            if approval {
                guard let session = callerManagedSession(),
                      coordinator.liveAgentSession(of: record, ownAgentOnly: true)?.sessionID == session.sessionID else {
                    throw AutomationSocketError.invalidPayload("Only the task's active agent can ask a checked approval question.")
                }
            }
            let updated = try perform {
                try coordinator.needsReply(taskID: record.id, question: args.taskString("question"), approval: approval, fleetChecks: fleetChecks)
            }
            return .init(didMutateState: true, result: Self.taskSnapshot(updated))
        case .taskAnswer:
            let record = try visibleTask(args: args, coordinator: coordinator)
            guard let questionID = args.taskString("questionID").flatMap(UUID.init(uuidString:)),
                  let webhookID = args.taskString("webhookID").flatMap(UUID.init(uuidString:)),
                  let decision = args.taskString("decision").flatMap(TaskApprovalAnswer.Decision.init(rawValue:)),
                  let signature = args.taskString("signature") else {
                throw AutomationSocketError.invalidPayload("Supply questionID, decision, webhookID and signature.")
            }
            let answer = try perform {
                try coordinator.answerApproval(
                    taskID: record.id, questionID: questionID, decision: decision, bot: (webhookID, signature)
                )
            }
            return .init(didMutateState: true, result: Self.approvalAnswerSnapshot(answer))
        case .taskWaiting:
            let record = try ownOrVisibleTask(args: args, coordinator: coordinator)
            let reason = args.taskString("on")
            let wakeText = args.taskString("wakeAt")
            if try args.taskBool("clear") == true {
                guard reason == nil, wakeText == nil else {
                    throw AutomationSocketError.invalidPayload("task.waiting takes clear alone, or on with an optional wakeAt")
                }
                let updated = try perform { try coordinator.clearWaiting(taskID: record.id) }
                return .init(didMutateState: true, result: Self.taskSnapshot(updated))
            }
            guard let reason else {
                throw AutomationSocketError.invalidPayload("task.waiting requires on, the thing the task waits for, or clear")
            }
            var wakeAt: Date?
            if let wakeText {
                guard let date = (try? Date(wakeText, strategy: .iso8601))
                    ?? (try? Date(wakeText, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) else {
                    throw AutomationSocketError.invalidPayload("wakeAt must be an ISO 8601 time, such as 2026-12-01T17:00:00Z")
                }
                wakeAt = date
            }
            let updated = try perform { try coordinator.setWaiting(taskID: record.id, reason: reason, wakeAt: wakeAt) }
            return .init(didMutateState: true, result: Self.taskSnapshot(updated))
        case .taskMarkDone:
            let record = try visibleTask(args: args, coordinator: coordinator)
            let updated = try perform { try coordinator.markDone(taskID: record.id) }
            return .init(didMutateState: true, result: Self.taskSnapshot(updated))
        case .taskArchive:
            throw AutomationSocketError.invalidPayload("task.archive checks git before it returns; send it through app_control.run_action")
        case .taskReleaseComplete:
            throw AutomationSocketError.invalidPayload("task.release-complete checks git before it returns; send it through app_control.run_action")
        case .taskSend:
            let queue = try args.taskBool("queue") == true
            guard try args.taskBool("steer") != true else {
                throw AutomationSocketError.invalidPayload(
                    queue ? "pass steer or queue, not both"
                        : "task.send with steer waits for the agent's state; send it through app_control.run_action"
                )
            }
            let record = try visibleTask(args: args, coordinator: coordinator)
            let message = try taskSendMessage(args: args)
            if queue {
                let from = Self.senderName(messageSender(statedName: try statedSenderName(args: args)))
                let (queued, position) = try perform { try coordinator.queueMessage(taskID: record.id, text: message, from: from) }
                return .init(didMutateState: true, result: Self.queuedSendResult(queued, taskID: record.id, position: position))
            }
            let session = try perform { try coordinator.send(taskID: record.id, text: message) }
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

    /// The request and its caller, read in this request's context.
    func taskCreateInputs(args: [String: AutomationJSONValue]) throws -> (TaskCoordinator, TaskCreateRequest, TaskCaller) {
        (try requiredTaskCoordinator(), try taskCreateRequest(args: args), taskCaller())
    }

    /// For `newProject`, makes the folder and its repository off the main
    /// thread, before the other checks.
    func makeTaskNewProject(
        _ coordinator: TaskCoordinator,
        _ request: TaskCreateRequest,
        caller: TaskCaller
    ) async throws -> (request: TaskCreateRequest, made: TaskNewProject?) {
        do {
            return try await coordinator.makeNewProjectIfRequested(request, caller: caller)
        } catch let error as TaskError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
    }

    /// The checks run now, in this request's context; the files are copied
    /// after an await, off the main thread.
    func prepareTaskCreate(_ coordinator: TaskCoordinator, _ request: TaskCreateRequest, caller: TaskCaller) throws -> TaskCreatePreparation {
        try perform { try coordinator.prepareCreate(request, caller: caller) }
    }

    func finishTaskCreate(_ coordinator: TaskCoordinator, _ preparation: TaskCreatePreparation) async throws -> AppControlActionOutcome {
        do {
            let record = try await coordinator.finishCreate(preparation)
            return .init(didMutateState: true, result: Self.taskSnapshot(record))
        } catch let error as TaskError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
    }

    /// What a `task.send` with `queue` returns: what happened to the message
    /// now, and its ID, which `task.get` lists under `queuedMessages`.
    private static func queuedSendResult(_ message: TaskQueuedMessage, taskID: UUID, position: Int?) -> [String: AutomationJSONValue] {
        var result: [String: AutomationJSONValue] = [
            "taskID": .string(taskID.uuidString),
            "messageID": .string(message.id.uuidString),
        ]
        switch message.outcome?.kind {
        case .sent?:
            result["delivery"] = .string("sent")
            result["delivered"] = .bool(true)
            result["message"] = .string("The agent was at its prompt. Toastty typed the message there.")
        case .sentUnconfirmed?:
            result["delivery"] = .string("sentUnconfirmed")
            result["delivered"] = .bool(true)
            result["message"] = .string(
                "Toastty typed the message at the agent's prompt, but the terminal did not confirm the Return key. Check the task's terminal before you send it again."
            )
        case .dropped?, nil:
            result["delivery"] = .string("queued")
            result["delivered"] = .bool(false)
            result["queuePosition"] = position.map(AutomationJSONValue.int) ?? .null
            result["message"] = .string(
                "Toastty saved the message and types it at the agent's next open prompt, after its turn ends. Nothing is typed until then. task get lists it under queuedMessages."
            )
        }
        if let sessionID = message.outcome?.sessionID {
            result["sessionID"] = .string(sessionID)
        }
        return result
    }

    /// The sender as `task.get` lists it under `queuedMessages`.
    static func senderName(_ sender: CoordinatorMessageHeader.Sender) -> String {
        switch sender {
        case .task(let id, let title): CoordinatorTaskLink.markdown(taskID: id, title: title)
        case .coordinator: "the coordinator"
        case .session(let id, let agent, _): "agent session \(id) (\(agent))"
        case .named(let name): "\(name) (named by the caller)"
        case .unknown: "a terminal command"
        }
    }

    /// The checks of a `task.send` with `steer`, in this request's context.
    /// `nil` for a send without it, which does not wait.
    func prepareTaskSteerSend(args: [String: AutomationJSONValue]) throws -> (TaskCoordinator, UUID, String)? {
        guard try args.taskBool("steer") == true else { return nil }
        guard try args.taskBool("queue") != true else {
            throw AutomationSocketError.invalidPayload("pass steer or queue, not both")
        }
        let coordinator = try requiredTaskCoordinator()
        let record = try visibleTask(args: args, coordinator: coordinator)
        return (coordinator, record.id, try taskSendMessage(args: args))
    }

    /// The text `task.send` types: a first line that names the sender, from
    /// the caller and never from the text, then the caller's text. An empty
    /// text is refused here, before the first line makes it look full.
    private func taskSendMessage(args: [String: AutomationJSONValue]) throws -> String {
        guard let text = args.taskString("text") else {
            throw AutomationSocketError.invalidPayload("text is required")
        }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AutomationSocketError.invalidPayload("The message is empty.")
        }
        return CoordinatorMessageHeader.message(
            from: messageSender(statedName: try statedSenderName(args: args)), text: text, toTask: true
        )
    }

    func finishTaskSteerSend(_ coordinator: TaskCoordinator, taskID: UUID, text: String) async throws -> AppControlActionOutcome {
        do {
            let (session, delivery) = try await coordinator.sendSteering(taskID: taskID, text: text)
            var result: [String: AutomationJSONValue] = [
                "taskID": .string(taskID.uuidString),
                "sessionID": .string(session.sessionID),
                "panelID": .string(session.panelID.uuidString),
                "delivery": .string(delivery.name),
                "message": .string(delivery.message),
                // False for a message that waits: nothing was typed yet.
                "delivered": .bool(true),
            ]
            if case .queued(let position) = delivery {
                result["delivered"] = .bool(false)
                result["queuePosition"] = .int(position)
            }
            return .init(didMutateState: false, result: result)
        } catch let error as TaskError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
    }

    /// The checks that need only the request's context; the git checks run
    /// after an await.
    func prepareTaskArchive(args: [String: AutomationJSONValue]) throws -> (TaskCoordinator, UUID, TaskArchiveOptions, dryRun: Bool) {
        let coordinator = try requiredTaskCoordinator()
        let record = try visibleTask(args: args, coordinator: coordinator)
        let options = TaskArchiveOptions(
            closePullRequest: try args.taskBool("closePullRequest") ?? false,
            deleteUnpushedCommits: try args.taskBool("deleteUnpushedCommits") ?? false,
            discardChanges: try args.taskBool("discardChanges") ?? false
        )
        return (coordinator, record.id, options, try args.taskBool("dryRun") ?? false)
    }

    func finishTaskArchive(
        _ coordinator: TaskCoordinator, taskID: UUID, options: TaskArchiveOptions, dryRun: Bool
    ) async throws -> AppControlActionOutcome {
        do {
            if dryRun {
                let preview = try await coordinator.archivePreview(taskID: taskID, options: options)
                return .init(didMutateState: false, result: [
                    "taskID": .string(taskID.uuidString),
                    "dryRun": .bool(true),
                    "summary": .array(preview.summary.map(AutomationJSONValue.string)),
                    "refusal": preview.refusal.map(AutomationJSONValue.string) ?? .null,
                ])
            }
            let record = try await coordinator.archive(taskID: taskID, options: options)
            return .init(didMutateState: true, result: Self.taskSnapshot(record))
        } catch let error as TaskError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
    }

    struct TaskMergePreparation {
        var coordinator: TaskCoordinator
        var taskID: UUID
        var expectedHead: String?
        var caller: TaskCaller
    }

    /// The checks that need the request's context: which task, and who asks.
    func prepareTaskMerge(args: [String: AutomationJSONValue]) throws -> TaskMergePreparation {
        let coordinator = try requiredTaskCoordinator()
        let record = try ownOrVisibleTask(args: args, coordinator: coordinator)
        return TaskMergePreparation(
            coordinator: coordinator, taskID: record.id, expectedHead: args.taskString("head"), caller: taskCaller()
        )
    }

    /// Starts the merge and answers once the pull request script has, with
    /// `merge` as `task.get` reports it. A refusal is an error with its reason.
    func finishTaskMerge(_ preparation: TaskMergePreparation) async throws -> AppControlActionOutcome {
        let coordinator = preparation.coordinator
        do {
            let record = try await coordinator.mergeAndAwaitAnswer(
                taskID: preparation.taskID, expectedHead: preparation.expectedHead, caller: preparation.caller
            )
            var result = Self.taskSnapshot(record)
            result["merge"] = coordinator.board?.mergeActivity(taskID: record.id).map { .string("\($0)") } ?? .null
            return .init(didMutateState: true, result: result)
        } catch let error as TaskError {
            throw AutomationSocketError.invalidPayload(error.message)
        }
    }

    /// `task.release`, once the caller's access to the workspace is checked.
    func runTaskRelease(workspaceID: UUID, args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        let coordinator = try requiredTaskCoordinator()
        let parentIDs = try requiredStore().state.subspaceParentIDsByWorkspaceID()
        try enforceWorkspaceAutomationAccess(parentIDs[workspaceID] ?? workspaceID)
        let record = try perform {
            try coordinator.release(
                workspaceID: workspaceID,
                caller: taskCaller(),
                agent: args.taskString("agent"),
                model: args.taskString("model"),
                effort: args.taskString("effort")
            )
        }
        return .init(didMutateState: true, result: Self.taskSnapshot(record))
    }

    func prepareTaskReleaseCompletion(args: [String: AutomationJSONValue]) throws -> (TaskCoordinator, TaskCaller, [TaskRelease.Tag]) {
        struct Report: Decodable {
            var tags: [TaskRelease.Tag]
        }
        guard let content = args.taskString("report"),
              let report = try? JSONDecoder().decode(Report.self, from: Data(content.utf8)) else {
            throw AutomationSocketError.invalidPayload("Expected a JSON report with tags, each with a tag name and a list of taskIDs.")
        }
        return (try requiredTaskCoordinator(), taskCaller(), report.tags)
    }

    func finishTaskReleaseCompletion(_ coordinator: TaskCoordinator, caller: TaskCaller, tags: [TaskRelease.Tag]) async throws -> AppControlActionOutcome {
        do {
            let record = try await coordinator.reportReleaseCompletion(caller: caller, tags: tags)
            return .init(didMutateState: true, result: Self.taskSnapshot(record))
        } catch {
            throw AutomationSocketError.invalidPayload(error.localizedDescription)
        }
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
        let stages = Self.stagesByTaskID(coordinator.recordStateTimes(), pullRequests: coordinator.board?.pullRequests)
        return .init(
            didMutateState: true,
            result: Self.taskSnapshot(coordinator.records.record(id: record.id) ?? record, stage: stages[record.id])
        )
    }

    func runTaskQuery(_ query: AppControlQueryID, args: [String: AutomationJSONValue]) throws -> [String: AutomationJSONValue] {
        let coordinator = try requiredTaskCoordinator()
        switch query {
        case .taskGet:
            // The times of state changes are brought up to date first, so
            // each belongs to the state this answer reports.
            let stages = Self.stagesByTaskID(coordinator.recordStateTimes(), pullRequests: coordinator.board?.pullRequests)
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
            return addingActivityTimes(
                to: liveTaskSnapshot(record, coordinator: coordinator, stage: stages[record.id], includeReply: true),
                record: record,
                coordinator: coordinator
            )
        case .taskList:
            let includeReply = try args.taskBool("includeReply") ?? false
            let stages = Self.stagesByTaskID(coordinator.recordStateTimes(), pullRequests: coordinator.board?.pullRequests)
            // Every task's snapshot goes to the change feed, so one caller's
            // poll never hides a change from another. The reply is left out
            // of what the feed compares: it changes only with agentState.
            // So are lastOutputAt and lastUserInputAt, which move while an
            // agent works or the user types and would list the task on
            // every poll.
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
                let snapshot = includeReply
                    ? liveTaskSnapshot(record, coordinator: coordinator, stage: stages[record.id], includeReply: true)
                    : snapshots[record.id] ?? [:]
                return .object(addingActivityTimes(to: snapshot, record: record, coordinator: coordinator))
            }
            return [
                "tasks": .array(tasks),
                "cursor": .string(changes.cursor),
                "deletedTaskIDs": .array(changes.deletedTasks.filter { callerMaySee($0.visibility) }.map { .string($0.id.uuidString) }),
                "reset": .bool(args.taskString("changedSince") != nil && changes.reset),
            ]
        case .taskWorkspaceChoices:
            let taskID = try args.taskString("taskID").map { raw -> UUID in
                guard let id = UUID(uuidString: raw), let record = coordinator.records.record(id: id), callerMaySee(record) else {
                    throw AutomationSocketError.invalidPayload("No task has ID \(raw).")
                }
                return id
            }
            var snapshot = workspaceChoicesSnapshot(coordinator.workspaceChoices(taskID: taskID))
            if let name = args.taskString("name") {
                let isScoped = requestContext().callerSessionID.map(callerIsWorkspaceScoped(sessionID:)) ?? false
                let matches = coordinator.projectMatches(named: name, workspaceScope: isScoped ? { self.callerMayAutomateWorkspace($0) } : nil)
                snapshot["matches"] = .array(projectMatchesSnapshot(matches))
            }
            return snapshot
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
    /// state, GitHub's last answer about the pull request and, when asked,
    /// the agent's last reply.
    private func liveTaskSnapshot(
        _ record: TaskRecord,
        coordinator: TaskCoordinator,
        stage: TaskStageSnapshot?,
        includeReply: Bool
    ) -> [String: AutomationJSONValue] {
        var snapshot = Self.taskSnapshot(record, stage: stage)
        snapshot["merge"] = coordinator.board?.mergeActivity(taskID: record.id).map { .string("\($0)") } ?? .null
        // After a merge, the earliest time Toastty closes the task space and
        // removes the worktree, so the task's agent can hand its work over.
        if let taskSpaceID = record.taskSpaceWorkspaceID,
           case .holdingCleanup(let until)? = coordinator.merges?.request(workspaceID: taskSpaceID)?.phase,
           case .object(var cleanup)? = snapshot["cleanup"] {
            cleanup["taskSpaceClosesAt"] = .string(ISO8601DateFormatter().string(from: until))
            snapshot["cleanup"] = .object(cleanup)
        }
        let status = coordinator.agentStatus(of: record)
        func optional(_ value: String?) -> AutomationJSONValue { value.map(AutomationJSONValue.string) ?? .null }
        snapshot["agentState"] = .object([
            "state": .string(status.activity.rawValue),
            "sessionID": optional(status.session?.sessionID),
            "panelID": optional(status.session?.panelID.uuidString),
            "summary": optional(status.session?.status?.summary),
            "failure": optional(status.session?.status?.claudeFableQuota == nil ? nil : "claudeFableQuota"),
            "recoveringModel": .bool(coordinator.recoveringFableTasks.contains(record.id)),
            "changedAt": optional(status.changedAt.map { ISO8601DateFormatter().string(from: $0) }),
            "lastTurnEndedAt": optional(status.session?.lastTurnEndedAt.map { ISO8601DateFormatter().string(from: $0) }),
            "interruptedAtQuit": .bool(coordinator.wasInterruptedAtQuit(record)),
        ])
        snapshot["pullRequest"] = stage?.pullRequest.map { .object(Self.pullRequestSnapshot($0, record: record)) } ?? .null
        // Why GitHub has not answered, while it has not.
        snapshot["pullRequestLookupError"] = stage?.pullRequestLookupProblem.map { problem in
            .object([
                "problem": .string(Self.lookupProblemName(problem)),
                "message": .string(TaskBoardPresentation.lookupProblemReason(problem)),
            ])
        } ?? .null
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

    /// Adds the two times that move without a change of state: the agent's
    /// last output and the user's last input.
    private func addingActivityTimes(
        to snapshot: [String: AutomationJSONValue],
        record: TaskRecord,
        coordinator: TaskCoordinator
    ) -> [String: AutomationJSONValue] {
        func date(_ value: Date?) -> AutomationJSONValue {
            value.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
        }
        var snapshot = snapshot
        if case .object(var agentState)? = snapshot["agentState"] {
            agentState["lastOutputAt"] = date(coordinator.lastOutputAt(of: record))
            snapshot["agentState"] = .object(agentState)
        }
        snapshot["lastUserInputAt"] = date(coordinator.lastUserInputAt(of: record))
        return snapshot
    }

    private static func lookupProblemName(_ problem: PullRequestLookupProblem) -> String {
        switch problem {
        case .ghMissing: "ghMissing"
        case .notSignedIn: "notSignedIn"
        case .other: "other"
        }
    }

    /// `pullRequest`: GitHub's last answer. `checks` is `pending`, `failing`
    /// or `passing`, and `null` when the commit has no checks or the answer
    /// did not say. `checksPendingSince` is when Toastty first saw them
    /// pending for the head commit.
    private static func pullRequestSnapshot(_ state: TaskPullRequestState, record: TaskRecord) -> [String: AutomationJSONValue] {
        func optional(_ value: String?) -> AutomationJSONValue { value.map(AutomationJSONValue.string) ?? .null }
        var checks: String?
        switch state.mergeability?.checks {
        case .passing?: checks = "passing"
        case .running?: checks = "pending"
        case .failing?: checks = "failing"
        case nil: checks = nil
        }
        let pendingSince = state.state == .open && checks == "pending" ? record.stateTimes?.checksPending?.since : nil
        return [
            "state": .string(state.state.rawValue),
            "isDraft": .bool(state.isDraft),
            "mergeStateStatus": optional(state.mergeability?.mergeState.rawValue.uppercased()),
            "checks": optional(checks),
            "checksPendingSince": optional(pendingSince.map { ISO8601DateFormatter().string(from: $0) }),
        ]
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
        // A project directory can open a new top-level workspace, which no
        // scope covers, so a scoped session names its workspace instead.
        var rootDirectory: String?
        if let raw = args.taskString("rootDirectory") {
            guard workspaceID == nil else {
                throw AutomationSocketError.invalidPayload("pass workspace or rootDirectory, not both")
            }
            let path = raw.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") || path.hasPrefix("~") else {
                throw AutomationSocketError.invalidPayload("rootDirectory must be an absolute path or start with ~")
            }
            if let callerSessionID = requestContext().callerSessionID, callerIsWorkspaceScoped(sessionID: callerSessionID) {
                throw AutomationSocketError.invalidPayload("a workspace-scoped session cannot create a task by rootDirectory; pass its workspace")
            }
            rootDirectory = path
        }
        let newProject = try args.taskBool("newProject") ?? false
        if newProject, rootDirectory == nil {
            throw AutomationSocketError.invalidPayload("newProject needs rootDirectory, the new project's folder")
        }
        return TaskCreateRequest(
            text: args.taskString("text") ?? "",
            files: try Self.taskStrings("files", args: args),
            clientRequestID: args.taskString("clientRequestID"),
            title: args.taskString("title"),
            slug: args.taskString("slug"),
            workspaceID: workspaceID,
            rootDirectory: rootDirectory,
            newProject: newProject,
            externalRefID: args.taskString("externalRef"),
            externalRefURL: args.taskString("externalURL"),
            agent: args.taskString("agent"),
            model: args.taskString("model"),
            effort: args.taskString("effort"),
            prompt: args.taskString("prompt"),
            startWork: try args.taskBool("startWork") ?? false,
            base: args.taskString("base"),
            branchPrefix: args.taskString("branchPrefix"),
            fork: try args.taskBool("fork") ?? false
        )
    }

    /// A scoped session may place a task only in a workspace in its scope,
    /// and may not reopen a closed one: that makes a new top-level
    /// workspace, which no scope covers.
    private func taskWorkspaceChoice(args: [String: AutomationJSONValue]) throws -> TaskWorkspaceChoice {
        let workspace = args.taskString("workspace")
        let recent = args.taskString("recentWorkspace")
        let rootDirectory = args.taskString("rootDirectory")
        if let rootDirectory {
            guard workspace == nil, recent == nil else {
                throw AutomationSocketError.invalidPayload("pass one of workspace, recentWorkspace or rootDirectory")
            }
            let path = rootDirectory.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") || path.hasPrefix("~") else {
                throw AutomationSocketError.invalidPayload("rootDirectory must be an absolute path or start with ~")
            }
            if let callerSessionID = requestContext().callerSessionID, callerIsWorkspaceScoped(sessionID: callerSessionID) {
                throw AutomationSocketError.invalidPayload("a workspace-scoped session cannot open a workspace")
            }
            return .directory(path)
        }
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
            throw AutomationSocketError.invalidPayload("pass one of workspace, recentWorkspace or rootDirectory")
        }
    }

    private func projectMatchesSnapshot(_ matches: [TaskProjectMatch]) -> [AutomationJSONValue] {
        matches.map { match -> AutomationJSONValue in
            var object: [String: AutomationJSONValue] = [
                "title": .string(match.title),
                "rootDirectory": .string(match.rootDirectory),
                "source": .string(match.source.rawValue),
            ]
            if let id = match.workspaceID { object["workspaceID"] = .string(id.uuidString) }
            if let id = match.recentWorkspaceID { object["recentWorkspace"] = .string(id.uuidString) }
            return .object(object)
        }
    }

    private func workspaceChoicesSnapshot(_ choices: TaskWorkspaceChoices) -> [String: AutomationJSONValue] {
        let isScoped = requestContext().callerSessionID.map(callerIsWorkspaceScoped(sessionID:)) ?? false
        let open = choices.open.filter { callerMayAutomateWorkspace($0.id) }.map { workspace -> AutomationJSONValue in
            var object: [String: AutomationJSONValue] = ["workspaceID": .string(workspace.id.uuidString), "title": .string(workspace.title)]
            if let root = workspace.rootDirectory { object["rootDirectory"] = .string(root) }
            return .object(object)
        }
        let recent = isScoped ? [] : choices.recent.map { item -> AutomationJSONValue in
            .object([
                "recentWorkspace": .string(item.id.uuidString),
                "title": .string(item.title),
                "rootDirectory": .string(item.rootDirectory),
                "closedAt": .string(ISO8601DateFormatter().string(from: item.closedAt)),
            ])
        }
        var snapshot: [String: AutomationJSONValue] = ["open": .array(open), "recent": .array(recent)]
        if let suggested = choices.suggested {
            var object: [String: AutomationJSONValue] = [
                "title": .string(suggested.title),
                "rootDirectory": .string(suggested.rootDirectory),
            ]
            // The task.set-workspace argument that places the task there.
            switch suggested.choice {
            case .open(let id):
                if callerMayAutomateWorkspace(id) { object["workspace"] = .string(id.uuidString) }
            case .recent(let id):
                if isScoped == false { object["recentWorkspace"] = .string(id.uuidString) }
            case .directory(let path):
                if isScoped == false { object["rootDirectory"] = .string(path) }
            }
            snapshot["suggested"] = .object(object)
        }
        return snapshot
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

    /// `pullRequests` gives GitHub's answers as given: the board's own copy
    /// keeps the last known checks while GitHub works out the merge state.
    private static func stagesByTaskID(_ items: [TaskBoardItem], pullRequests: PullRequestStateCache?) -> [UUID: TaskStageSnapshot] {
        Dictionary(items.compactMap { item in
            item.taskID.map {
                ($0, TaskStageSnapshot(
                    stage: item.stage,
                    finishedThroughChildren: item.finishedThroughChildren,
                    pullRequest: item.pullRequest.flatMap { pullRequests?.answer(for: $0) },
                    pullRequestLookupProblem: item.pullRequestLookupProblem
                ))
            }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// `stage` as `{group, needsUser, changedAt, attention?, reason?,
    /// finishedThroughChildren?}`: the group the Tasks view lists the task
    /// in, when its group or attention last changed, why it needs the user,
    /// and whether it reached To ship or Done through its child tasks.
    static func stageSnapshot(_ snapshot: TaskStageSnapshot, changedAt: Date?) -> [String: AutomationJSONValue] {
        let stage = snapshot.stage
        var result: [String: AutomationJSONValue] = [
            "group": .string("\(stage.group)"),
            "needsUser": .bool(stage.needsUser),
            "changedAt": changedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
        ]
        if snapshot.finishedThroughChildren {
            result["finishedThroughChildren"] = .bool(true)
        }
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
            case .startWaitsInTerminal: result["attention"] = .string("startWaitsInTerminal")
            case .awaitingReply: result["attention"] = .string("awaitingReply")
            case .agentError: result["attention"] = .string("agentError")
            case .review: result["attention"] = .string("review")
            case .readyForReview: result["attention"] = .string("readyForReview")
            case .agentFinished: result["attention"] = .string("agentFinished")
            case .cleanupStopped(let reason):
                result["attention"] = .string("cleanupStopped")
                result["reason"] = .string(reason)
            }
        }
        return result
    }

    static func approvalAnswerSnapshot(_ answer: TaskApprovalAnswer) -> [String: AutomationJSONValue] {
        [
            "id": .string(answer.id.uuidString),
            "questionID": .string(answer.questionID.uuidString),
            "decision": .string(answer.decision.rawValue),
            "question": .string(answer.question),
            "delivery": .string(answer.delivery.rawValue),
            "sessionID": answer.sessionID.map(AutomationJSONValue.string) ?? .null,
            "webhookName": answer.grant.map { .string($0.webhookName) } ?? .null,
        ]
    }

    static func taskSnapshot(_ record: TaskRecord, stage: TaskStageSnapshot? = nil) -> [String: AutomationJSONValue] {
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
        case .remoteDevice: source = "remoteDevice"
        }
        var snapshot: [String: AutomationJSONValue] = [
            "taskID": .string(record.id.uuidString),
            "parentTaskID": optional(record.parentTaskID?.uuidString),
            "title": .string(record.title),
            // The task as an agent names it in text; the ID is for commands.
            "markdownLink": .string(CoordinatorTaskLink.markdown(taskID: record.id, title: record.title)),
            "slug": .string(record.slug),
            "text": .string(record.text),
            "createdAt": .string(ISO8601DateFormatter().string(from: record.createdAt)),
            "source": .string(source),
            "clientRequestID": optional(record.clientRequestID),
            "externalRef": record.externalRef.map {
                .object(["id": .string($0.id), "url": optional($0.url)])
            } ?? .null,
            "workspaceID": optional(record.workspaceID?.uuidString),
            "projectRoot": optional(record.projectRoot),
            "agent": optional(record.resolved?.agent),
            "model": optional(record.resolved?.model),
            "effort": optional(record.resolved?.effort),
            "prompt": optional(record.resolved?.prompt),
            "triageNote": optional(record.triageNote),
            "suggestedWorkspace": record.suggestedWorkspace.map {
                .object(["title": .string($0.title), "rootDirectory": .string($0.rootDirectory)])
            } ?? .null,
            "files": .array(record.attachments.map { .string($0.path) }),
            "filesRemovedAt": date(record.attachmentsRemovedAt),
            "setup": .object(setup),
            "sessionID": optional(record.currentSessionID),
            "pullRequestURL": optional(record.pullRequestURL),
            "mergedAt": date(record.mergedAt),
            "mergeCommit": optional(record.mergeCommit),
            "readyForReviewAt": date(record.readyForReviewAt),
            "replyRequest": record.replyRequest.map {
                .object([
                    "askedAt": date($0.askedAt), "question": optional($0.question),
                    "approvalID": optional($0.approvalID?.uuidString),
                    "fleetChecks": $0.fleetChecks.map {
                        .object(["version": .string($0.version), "targets": .array($0.targets.map(AutomationJSONValue.string))])
                    } ?? .null,
                ])
            } ?? .null,
            "lastApprovalAnswer": record.lastApprovalAnswer.map { .object(approvalAnswerSnapshot($0)) } ?? .null,
            "waiting": record.waiting.map {
                .object(["on": .string($0.on), "since": date($0.since), "wakeAt": date($0.wakeAt), "wokenAt": date($0.wokenAt)])
            } ?? .null,
            // Messages from task.send with queue, and their outcome.
            "queuedMessages": .array((record.queuedMessages ?? []).map { message in
                .object([
                    "messageID": .string(message.id.uuidString),
                    "from": .string(message.from),
                    "queuedAt": date(message.queuedAt),
                    "state": .string(message.outcome?.kind.rawValue ?? "queued"),
                    "at": date(message.outcome?.at),
                    "sessionID": optional(message.outcome?.sessionID),
                    "reason": optional(message.outcome?.reason),
                ])
            }),
            "mergeRequestedAt": date(record.mergeRequestedAt),
            "mergeCancelledAt": date(record.mergeCancelledAt),
            "mergeFailure": record.mergeFailure.map {
                .object([
                    "at": date($0.at), "reason": .string($0.reason),
                    "cause": optional($0.cause?.rawValue), "head": optional($0.head), "base": optional($0.base),
                ])
            } ?? .null,
            "releaseAfterMerge": record.releaseAfterMerge.map {
                .object(["requestedAt": date($0.requestedAt)])
            } ?? .null,
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
            var fields: [String: AutomationJSONValue] = [
                "childTaskIDs": .array(release.childTaskIDs.map { .string($0.uuidString) }),
            ]
            if let completion = release.completion {
                fields["completion"] = .object([
                    "reportedAt": date(completion.reportedAt),
                    "tags": .array(completion.tags.map { entry in
                        .object(["tag": .string(entry.tag), "taskIDs": .array(entry.taskIDs.map { .string($0.uuidString) })])
                    }),
                ])
            }
            snapshot["release"] = .object(fields)
        }
        if let stage {
            snapshot["stage"] = .object(stageSnapshot(
                stage, changedAt: TaskCoordinator.stageChangedAt(record, stage: stage.stage)
            ))
        }
        if let startWork = record.startWork {
            snapshot["worktree"] = .object(worktreeSnapshot(record, startWork: startWork))
        }
        if let forkSource = record.forkSource {
            snapshot["fork"] = .object([
                "sourceSessionID": .string(forkSource.sessionID),
                "sourceConversationID": optional(forkSource.conversationID),
                "conversationConfirmed": .bool(record.operation.agentLaunch?.forkConversationID != nil),
            ])
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

/// A task's stage as `task get` and `task list` report it.
struct TaskStageSnapshot: Equatable {
    var stage: TaskStage
    /// The task reached To ship or Done because its child tasks finished.
    var finishedThroughChildren = false
    /// GitHub's last answer about the task's pull request, if any.
    var pullRequest: TaskPullRequestState?
    /// Why GitHub has not answered about it, while it has not.
    var pullRequestLookupProblem: PullRequestLookupProblem?
}
