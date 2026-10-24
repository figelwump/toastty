import CoreState
import Foundation

extension AppControlActionID {
    var isCoordinatorReviewAction: Bool { self == .coordinatorReviewPublish || self == .coordinatorReviewReport }
}

extension AppControlQueryID {
    var isCoordinatorReviewQuery: Bool { self == .coordinatorReviewGet || self == .coordinatorReviewList }
}

extension AppControlExecutor {
    /// Assembly installs the same retained actions used by the native home.
    /// Approval and feedback are deliberately absent from the agent catalog.
    func installCoordinatorReviews(_ actions: CoordinatorReviewActions) {
        installedCoordinatorReviewActions = actions
    }

    func runCoordinatorReviewAction(_ action: AppControlActionID, args: [String: AutomationJSONValue]) throws -> AppControlActionOutcome {
        do {
            let actions = try requiredCoordinatorReviews()
            let tasks = try requiredTaskCoordinator()
            switch action {
            case .coordinatorReviewPublish:
                let record = try visibleTask(args: args, coordinator: tasks)
                let target = try tasks.mergeTarget(record)
                guard let root = record.projectRoot, let head = args.string("head"), let base = args.string("baseRefName") else {
                    throw TaskError("A review requires the task's project, full PR head and baseRefName.")
                }
                let brief: CoordinatorReviewBrief = try Self.decodeReviewValue(args["brief"], name: "brief")
                let inputs: [CoordinatorEvidenceInput] = try args["evidenceFiles"].map { try Self.decodeReviewValue($0, name: "evidenceFiles") } ?? []
                let files = try inputs.map { input -> CoordinatorReviewStore.EvidenceFile in
                    guard input.filePath.hasPrefix("/"), !input.filePath.contains("\0") else {
                        throw TaskError("Evidence filePath must be an absolute path.")
                    }
                    return .init(evidenceIndex: input.evidenceIndex, fileURL: URL(fileURLWithPath: input.filePath))
                }
                let item = try actions.store.upsertPublication(CoordinatorReviewItem(
                    taskID: record.id, taskTitle: record.title, projectRoot: root,
                    repository: target.pullRequest.repository, pullRequestURL: target.pullRequest.url,
                    headSHA: head.lowercased(), baseRefName: base, brief: brief
                ), evidenceFiles: files)
                return .init(didMutateState: true, result: ["review": try Self.reviewJSON(item)])
            case .coordinatorReviewReport:
                let item = try visibleReview(args: args, actions: actions, tasks: tasks)
                if let caller = callerManagedSession() {
                    let record = tasks.records.record(id: item.taskID)
                    let agentSessionID = record.flatMap { tasks.liveAgentSession(of: $0)?.sessionID }
                    guard tasks.task(inWorkspace: caller.workspaceID)?.id == item.taskID
                        || agentSessionID == caller.sessionID else {
                        throw TaskError("Only the task's agent can report this review action.")
                    }
                }
                guard let rawIntent = args.string("intentID"), let intent = UUID(uuidString: rawIntent),
                      let rawOutcome = args.string("outcome"), let outcome = CoordinatorReviewAction.AgentOutcome.State(rawValue: rawOutcome),
                      let detail = args.string("detail") else { throw TaskError("A report needs intentID, outcome and detail.") }
                try actions.report(reviewID: item.id, intentID: intent, outcome: outcome, detail: detail)
                return .init(didMutateState: true, result: ["review": try Self.reviewJSON(actions.store.item(id: item.id) ?? item)])
            default:
                throw TaskError("Unsupported review action.")
            }
        } catch let error as AutomationSocketError { throw error }
        catch { throw AutomationSocketError.invalidPayload(error.localizedDescription) }
    }

    func runCoordinatorReviewQuery(_ query: AppControlQueryID, args: [String: AutomationJSONValue]) throws -> [String: AutomationJSONValue] {
        let actions = try requiredCoordinatorReviews()
        let tasks = try requiredTaskCoordinator()
        switch query {
        case .coordinatorReviewGet:
            return ["review": try Self.reviewJSON(visibleReview(args: args, actions: actions, tasks: tasks))]
        case .coordinatorReviewList:
            let filter: UUID?
            if let raw = args.string("taskID") {
                guard let id = UUID(uuidString: raw) else { throw AutomationSocketError.invalidPayload("taskID must be a UUID") }
                filter = id
            } else { filter = nil }
            let limit = args.int("limit") ?? 20
            guard (1...100).contains(limit) else { throw AutomationSocketError.invalidPayload("limit must be from 1 to 100") }
            let visible = actions.store.items.filter { (filter == nil || $0.taskID == filter) && reviewIsVisible($0, tasks: tasks) }
            let start: Int
            if let raw = args.string("after") {
                guard let id = UUID(uuidString: raw), let index = visible.firstIndex(where: { $0.id == id }) else {
                    throw AutomationSocketError.invalidPayload("after must name a visible review in this list")
                }
                start = index + 1
            } else { start = 0 }
            var page: [AutomationJSONValue] = []
            var bytes = 0
            var end = start
            for item in visible.dropFirst(start).prefix(limit) {
                let value = try Self.reviewJSON(item)
                let size = try JSONEncoder().encode(value).count
                if !page.isEmpty && bytes + size > 524_288 { break }
                page.append(value)
                bytes += size
                end += 1
            }
            return [
                "reviews": .array(page),
                "nextAfter": end < visible.count && end > start ? .string(visible[end - 1].id.uuidString) : .null,
                "loadError": actions.store.loadError.map(AutomationJSONValue.string) ?? .null,
            ]
        default:
            throw AutomationSocketError.invalidPayload("Unsupported review query")
        }
    }

    private func requiredCoordinatorReviews() throws -> CoordinatorReviewActions {
        guard let coordinatorReviewActions else { throw AutomationSocketError.invalidPayload("Coordinator reviews are unavailable in this instance") }
        return coordinatorReviewActions
    }

    private func visibleReview(args: [String: AutomationJSONValue], actions: CoordinatorReviewActions, tasks: TaskCoordinator) throws -> CoordinatorReviewItem {
        guard let raw = args.string("reviewID"), let id = UUID(uuidString: raw),
              let item = actions.store.item(id: id), reviewIsVisible(item, tasks: tasks) else {
            throw AutomationSocketError.invalidPayload("No visible review has that reviewID")
        }
        return item
    }

    private func reviewIsVisible(_ item: CoordinatorReviewItem, tasks: TaskCoordinator) -> Bool {
        if let record = tasks.records.record(id: item.taskID) { return callerMaySee(record) }
        // User/global readers retain the record after explicit task deletion.
        guard let session = requestContext().callerSessionID else { return true }
        return !callerIsWorkspaceScoped(sessionID: session)
    }

    private static func decodeReviewValue<Value: Decodable>(_ value: AutomationJSONValue?, name: String) throws -> Value {
        guard let value else { throw TaskError("\(name) is required.") }
        let data: Data
        if case .string(let json) = value { data = Data(json.utf8) }
        else { data = try JSONEncoder().encode(value) }
        guard data.count <= 262_144 else { throw TaskError("\(name) is too large.") }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw TaskError("\(name) is not valid review JSON: \(error.localizedDescription)") }
    }

    private static func reviewJSON(_ item: CoordinatorReviewItem) throws -> AutomationJSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(AutomationJSONValue.self, from: encoder.encode(item))
    }
}

private struct CoordinatorEvidenceInput: Decodable {
    let evidenceIndex: Int
    let filePath: String
}
