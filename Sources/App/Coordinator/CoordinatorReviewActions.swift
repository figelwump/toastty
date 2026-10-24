import Combine
import CoreState
import Foundation

extension CoordinatorReviewStore {
    convenience init(runtimePaths: ToasttyRuntimePaths) {
        self.init(fileURL: runtimePaths.coordinatorReviewsFileURL, evidenceDirectoryURL: runtimePaths.coordinatorReviewEvidenceDirectoryURL)
    }
}

/// Native user decisions enter here. Agents can publish briefs and report
/// progress, but those operations cannot create an approval.
@MainActor
final class CoordinatorReviewActions: ObservableObject {
    let store: CoordinatorReviewStore
    @Published private(set) var error: String?
    private weak var tasks: TaskCoordinator?
    private let pullRequests: PullRequestStateCache
    private let now: () -> Date
    private let deliveryPollInterval: Duration
    private let deliveryTimeout: Duration
    private var deliveries: [UUID: Task<Void, Never>] = [:]
    private var observation: AnyCancellable?

    init(
        store: CoordinatorReviewStore, tasks: TaskCoordinator, pullRequests: PullRequestStateCache,
        now: @escaping () -> Date = Date.init,
        deliveryPollInterval: Duration = .seconds(1), deliveryTimeout: Duration = .seconds(30 * 60)
    ) {
        self.store = store
        self.tasks = tasks
        self.pullRequests = pullRequests
        self.now = now
        self.deliveryPollInterval = deliveryPollInterval
        self.deliveryTimeout = deliveryTimeout
        tasks.coordinatorReviewActions?.stopDeliveries()
        tasks.coordinatorReviewActions = self
        // A crash can occur on either side of a terminal write. Never infer
        // that repeating an unfinished intent is safe.
        for item in store.items where item.userAction?.deliveryState == .dispatching || item.userAction?.deliveryState == .pending {
            do {
                try store.update(id: item.id, expectedRevision: item.revision) {
                    $0.userAction?.deliveryState = item.userAction?.deliveryState == .dispatching ? .uncertain : .failed
                    $0.userAction?.updatedAt = now()
                    $0.userAction?.deliveryDetail = "Toastty restarted before delivery was confirmed. Check the task before retrying."
                }
                if let intent = item.userAction?.intentID { try clearLegacyMergeStatus(taskID: item.taskID, intentID: intent) }
            } catch { self.error = error.localizedDescription }
        }
        observation = pullRequests.$entries.sink { [weak self] entries in
            self?.observe(entries)
        }
    }

    @discardableResult
    func approveAndMerge(reviewID: UUID, expectedRevision: Int) async throws -> CoordinatorReviewItem {
        try await approveAndMerge(reviewID: reviewID, expectedRevision: expectedRevision, confirmRedelivery: false)
    }

    /// An explicit native Retry action is needed before repeating a write
    /// whose submission was uncertain. It creates a new intent.
    @discardableResult
    func retryDelivery(reviewID: UUID, expectedRevision: Int) async throws -> CoordinatorReviewItem {
        let item = try displayedReview(reviewID, revision: expectedRevision)
        guard let action = item.userAction,
              action.deliveryState == .uncertain || action.deliveryState == .failed
                || (action.deliveryState == .delivered && [.blocked, .failed].contains(action.agentOutcome?.state)) else {
            throw TaskError("Only an uncertain delivery or a failed or blocked request can be retried.")
        }
        if action.kind == .merge {
            return try await approveAndMerge(reviewID: reviewID, expectedRevision: expectedRevision, confirmRedelivery: true)
        }
        return try await requestChanges(reviewID: reviewID, expectedRevision: expectedRevision, feedback: action.feedback ?? "")
    }

    private func approveAndMerge(reviewID: UUID, expectedRevision: Int, confirmRedelivery: Bool) async throws -> CoordinatorReviewItem {
        let displayed = try displayedReview(reviewID, revision: expectedRevision)
        guard let tasks, let record = tasks.records.record(id: displayed.taskID) else {
            throw TaskError("The reviewed task is unavailable.")
        }
        let target = try tasks.mergeTarget(record)
        guard target.pullRequest.url == displayed.pullRequestURL else { throw TaskError("The task's pull request changed. Refresh the review.") }
        try await requireCurrentHead(displayed)
        let current = try unchangedReview(displayed)
        if let previous = current.userAction, previous.kind == .merge,
           [.pending, .dispatching, .delivered, .uncertain].contains(previous.deliveryState),
           !(confirmRedelivery && (previous.deliveryState == .uncertain
                || (previous.deliveryState == .delivered && [.blocked, .failed].contains(previous.agentOutcome?.state)))) {
            throw TaskError("This approval already has a delivery. Check its status before retrying.")
        }
        guard let liveRecord = tasks.records.record(id: current.taskID),
              try tasks.mergeTarget(liveRecord).pullRequest.url == current.pullRequestURL else {
            throw TaskError("The task's pull request changed while checking it. Refresh the review.")
        }
        try supersedeOtherActions(taskID: current.taskID, keepingReviewID: current.id)
        let action = CoordinatorReviewAction(kind: .merge, approvedHeadSHA: current.headSHA, requestedAt: now())
        let accepted = try store.update(id: current.id, expectedRevision: current.revision) { $0.userAction = action }
        do {
            try tasks.saveMergeState(taskID: current.taskID) {
                $0.reviewActionIntentID = action.intentID
                $0.mergeRequestedAt = self.now()
                $0.mergeCancelledAt = nil
            }
        } catch {
            try? markDelivery(reviewID: current.id, intentID: action.intentID, state: .failed, message: error.localizedDescription)
            throw error
        }
        tasks.mergeDeliveryTasks.removeValue(forKey: current.taskID)?.cancel()
        scheduleDelivery(accepted)
        return accepted
    }

    @discardableResult
    func requestChanges(reviewID: UUID, expectedRevision: Int, feedback: String) async throws -> CoordinatorReviewItem {
        let current = try displayedReview(reviewID, revision: expectedRevision)
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= CoordinatorReviewAction.maximumFeedbackLength else {
            throw TaskError("Feedback must contain 1 to \(CoordinatorReviewAction.maximumFeedbackLength) characters.")
        }
        guard let tasks, let record = tasks.records.record(id: current.taskID) else { throw TaskError("The reviewed task is unavailable.") }
        _ = try tasks.mergeTarget(record)
        if record.mergeRequestedAt != nil { try tasks.cancelMerge(taskID: current.taskID) }
        let refreshed = try unchangedReview(current, allowActionChange: true)
        try supersedeOtherActions(taskID: current.taskID, keepingReviewID: current.id)
        let action = CoordinatorReviewAction(kind: .changesRequested, approvedHeadSHA: refreshed.headSHA, feedback: text, requestedAt: now())
        let accepted = try store.update(id: refreshed.id, expectedRevision: refreshed.revision) { $0.userAction = action }
        do {
            try tasks.saveMergeState(taskID: current.taskID) {
                $0.reviewActionIntentID = action.intentID
                $0.mergeRequestedAt = nil
                $0.mergeCancelledAt = self.now()
            }
        } catch {
            try? markDelivery(reviewID: current.id, intentID: action.intentID, state: .failed, message: error.localizedDescription)
            throw error
        }
        scheduleDelivery(accepted)
        return accepted
    }

    func setPriority(reviewID: UUID, expectedRevision: Int, priority: CoordinatorReviewBrief.Priority?) throws {
        try store.update(id: reviewID, expectedRevision: expectedRevision) { $0.priorityOverride = priority }
    }

    /// Build the queue from native task facts, including tasks that have no
    /// brief. The coordinator session is not part of this path.
    func reconcile(tasks items: [TaskBoardItem]) {
        let dependencies = Set(items.flatMap { ($0.record?.watches ?? []).filter(\.isPending).map(\.targetTaskID) })
        store.reconcile(items.compactMap { item in
            guard let record = item.record else { return nil }
            let urgent: Bool
            switch item.stage {
            case .needsYou(.agentNeedsInput), .needsYou(.agentError), .needsYou(.setupFailed), .needsYou(.moveFailed), .needsYou(.cleanupStopped): urgent = true
            default: urgent = false
            }
            return CoordinatorReviewTaskFacts(
                taskID: record.id, taskTitle: item.title, projectRoot: record.projectRoot ?? "",
                pullRequestURL: item.pullRequest?.url ?? record.pullRequestURL, headSHA: item.pullRequestState?.headSHA,
                baseRefName: item.pullRequestState?.baseRefName,
                needsReview: item.stage.needsUser, isUrgent: urgent, blocksOtherWork: dependencies.contains(record.id)
            )
        })
        for item in items {
            if let link = item.pullRequest, let state = item.pullRequestState { observe(link: link, state: state) }
        }
    }

    func report(reviewID: UUID, intentID: UUID, outcome: CoordinatorReviewAction.AgentOutcome.State, detail: String) throws {
        guard let item = store.item(id: reviewID), let action = item.userAction, action.intentID == intentID else {
            throw TaskError("This report has no matching user decision.")
        }
        guard action.deliveryState != .pending, action.deliveryState != .failed else {
            throw TaskError("This decision was not dispatched or was cancelled.")
        }
        let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= CoordinatorReviewAction.maximumFeedbackLength else { throw TaskError("Provide a bounded report detail.") }
        if action.agentOutcome?.state == outcome, action.agentOutcome?.message == text { return }
        try store.update(id: reviewID, expectedRevision: item.revision) {
            $0.userAction?.agentOutcome = .init(state: outcome, message: text, reportedAt: self.now())
            $0.userAction?.updatedAt = self.now()
        }
        // The report may say "merged" before GitHub answered. It never
        // writes observedOutcome; a fresh native observation confirms it.
        if let link = WorkspacePullRequestLink(annotationURL: item.pullRequestURL) { pullRequests.refresh(link) }
    }

    func validateMerge(taskID: UUID, pullRequestURL: String, intentID: UUID, suppliedIntentID: UUID?, expectedHead: String?) throws -> String {
        guard let item = store.items.first(where: { $0.taskID == taskID && $0.userAction?.intentID == intentID }),
              let action = item.userAction, action.kind == .merge,
              item.pullRequestURL == pullRequestURL,
              [.dispatching, .delivered, .uncertain].contains(action.deliveryState),
              action.agentOutcome?.state != .headChanged,
              item.observedOutcome.state == .open,
              let base = item.baseRefName, item.observedOutcome.baseRefName == base else {
            throw TaskError("The review approval is stale, cancelled, or belongs to another request. Approve the current change again.")
        }
        guard let expectedHead, expectedHead.lowercased() == action.approvedHeadSHA.lowercased() else {
            throw TaskError("Pass the full approved commit with --head \(action.approvedHeadSHA). A different head needs a new review.")
        }
        guard suppliedIntentID == intentID else { throw TaskError("Pass the matching user approval with --review-intent \(intentID.uuidString).") }
        return base
    }

    func cancelDelivery(taskID: UUID) throws {
        deliveries.removeValue(forKey: taskID)?.cancel()
        guard let intent = tasks?.records.record(id: taskID)?.reviewActionIntentID,
              let item = store.items.first(where: { $0.userAction?.intentID == intent }) else { return }
        try markDelivery(reviewID: item.id, intentID: intent, state: .failed, message: "The user cancelled this request.")
    }

    func supersedeDelivery(taskID: UUID) {
        do { try supersedeOtherActions(taskID: taskID, keepingReviewID: nil) }
        catch { self.error = error.localizedDescription }
    }

    private func supersedeOtherActions(taskID: UUID, keepingReviewID: UUID?) throws {
        deliveries.removeValue(forKey: taskID)?.cancel()
        for item in store.items where item.taskID == taskID && item.id != keepingReviewID {
            guard let action = item.userAction, action.deliveryState != .failed,
                  item.observedOutcome.state != .merged else { continue }
            try markDelivery(reviewID: item.id, intentID: action.intentID, state: .failed, message: "A newer user action replaced this request.")
        }
    }

    private func stopDeliveries() {
        for task in deliveries.values { task.cancel() }
        deliveries.removeAll()
    }

    private func displayedReview(_ id: UUID, revision: Int) throws -> CoordinatorReviewItem {
        if let error = store.loadError { throw TaskError("Review storage is unavailable: \(error)") }
        guard let item = store.item(id: id) else { throw TaskError("The review is unavailable.") }
        guard item.revision == revision else { throw TaskError("The review changed. Refresh it before deciding.") }
        guard item.observedOutcome.state != .merged, item.observedOutcome.state != .closed else {
            throw TaskError("This pull request is already merged or closed.")
        }
        return item
    }

    private func unchangedReview(_ displayed: CoordinatorReviewItem, allowActionChange: Bool = false) throws -> CoordinatorReviewItem {
        guard let current = store.item(id: displayed.id), current.brief == displayed.brief,
              allowActionChange || current.userAction == displayed.userAction else {
            throw TaskError("The review changed while checking the pull request. Refresh before deciding.")
        }
        return current
    }

    private func requireCurrentHead(_ item: CoordinatorReviewItem) async throws {
        guard let link = WorkspacePullRequestLink(annotationURL: item.pullRequestURL) else { throw TaskError("The review has no valid pull request.") }
        await pullRequests.refresh(link).value
        guard let entry = pullRequests.entries[link.url], entry.lastError == nil, let state = entry.state else {
            throw TaskError("Toastty could not verify the current PR head. \(pullRequests.entries[link.url]?.lastError ?? "Try again when GitHub is available.")")
        }
        guard state.state == .open, let head = state.headSHA, head.lowercased() == item.headSHA.lowercased(),
              let base = item.baseRefName, state.baseRefName == base else {
            throw TaskError("The pull request changed or closed. Review its current commit before merging.")
        }
    }

    private func scheduleDelivery(_ item: CoordinatorReviewItem) {
        guard let action = item.userAction else { return }
        deliveries.removeValue(forKey: item.taskID)?.cancel()
        deliveries[item.taskID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.deliver(reviewID: item.id, intentID: action.intentID)
            } catch is CancellationError {
                // A newer native decision owns the task now.
            } catch {
                self.error = error.localizedDescription
                do { try self.markDelivery(reviewID: item.id, intentID: action.intentID, state: .failed, message: error.localizedDescription) }
                catch { self.error = error.localizedDescription }
            }
            if self.store.item(id: item.id)?.userAction?.intentID == action.intentID { self.deliveries[item.taskID] = nil }
        }
    }

    private func deliver(reviewID: UUID, intentID: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: deliveryTimeout)
        while let tasks, let item = store.item(id: reviewID), let action = item.userAction, action.intentID == intentID {
            try Task.checkCancellation()
            guard tasks.coordinatorReviewActions === self,
                  tasks.records.record(id: item.taskID)?.reviewActionIntentID == intentID else { throw CancellationError() }
            guard let record = tasks.records.record(id: item.taskID) else { throw TaskError("The reviewed task is unavailable.") }
            if tasks.liveAgentSession(of: record)?.isInTurn == true {
                guard ContinuousClock.now < deadline else { throw TaskError("The task agent did not finish its turn before the delivery deadline.") }
                try await Task.sleep(for: deliveryPollInterval)
                continue
            }
            if action.kind == .merge { try await requireCurrentHead(item) }
            try Task.checkCancellation()
            guard store.item(id: reviewID)?.userAction?.intentID == intentID,
                  tasks.records.record(id: item.taskID)?.reviewActionIntentID == intentID else { throw CancellationError() }
            guard let currentRecord = tasks.records.record(id: item.taskID) else { throw TaskError("The reviewed task is unavailable.") }
            let target = try tasks.mergeTarget(currentRecord)
            guard target.pullRequest.url == item.pullRequestURL else { throw TaskError("The task's pull request changed.") }
            let config = try tasks.configLoader()
            let project = record.projectRoot.flatMap { config.workspace(forProjectRoot: $0, homeDirectoryPath: tasks.homeDirectoryPath) }
            let message: String
            if action.kind == .merge {
                guard let base = item.baseRefName else { throw TaskError("Publish a review that names the destination branch before merging.") }
                message = TaskPrompt.reviewedMerge(
                    skill: project?.mergeSkill ?? config.defaults.mergeSkill, prompt: project?.mergePrompt ?? config.defaults.mergePrompt,
                    pullRequestURL: item.pullRequestURL, approvedHead: item.headSHA, approvedBase: base, reviewID: item.id, intentID: intentID
                )
            } else {
                message = TaskPrompt.reviewChanges(pullRequestURL: item.pullRequestURL, reviewedHead: item.headSHA, feedback: action.feedback ?? "", reviewID: item.id, intentID: intentID)
            }
            try markDelivery(reviewID: reviewID, intentID: intentID, state: .dispatching)
            if let session = tasks.liveAgentSession(of: record) {
                // A refreshed PR request can yield while this session starts
                // another turn. Wait again instead of typing into it.
                if session.isInTurn { continue }
                guard tasks.sessions?.hasInput(panelID: session.panelID, since: action.requestedAt) != true else {
                    throw TaskError("Input reached this task after the decision. Inspect the task before retrying delivery.")
                }
                switch tasks.sessions?.deliver(message, panelID: session.panelID) ?? .unavailable {
                case .delivered: try markDelivery(reviewID: reviewID, intentID: intentID, state: .delivered)
                case .uncertain: try markDelivery(reviewID: reviewID, intentID: intentID, state: .uncertain, message: "Text reached the terminal but submission is uncertain. Check the task before retrying.")
                case .unavailable: throw TaskError("The task terminal is unavailable. The request was not delivered.")
                }
            } else {
                guard let launcher = tasks.launcher,
                      let profile = record.resolved?.agent ?? config.defaults.agent,
                      let panel = tasks.reusablePanel(in: target.taskSpaceID, preferred: UUID(), directory: target.repoPath) else {
                    throw TaskError("Toastty could not start the task's agent for this request.")
                }
                _ = try await TaskCoordinator.launchWhenTerminalIsReady(timeout: tasks.terminalReadinessTimeout) {
                    try await launcher.launchTask(
                        profileID: profile, workspaceID: target.taskSpaceID, panelID: panel, cwd: target.repoPath,
                        model: record.resolved?.agent == profile ? record.resolved?.model : config.defaults.model,
                        reasoningEffort: record.resolved?.agent == profile ? record.resolved?.effort : config.defaults.effort,
                        initialPrompt: message, parentSessionID: nil, forkFromSessionID: nil,
                        scopedWorkspaceIDs: record.creatorScope.map { $0.union([target.taskSpaceID]) },
                        beforeDispatch: { [weak self] in
                            guard !Task.isCancelled, self?.store.item(id: reviewID)?.userAction?.intentID == intentID,
                                  tasks.records.record(id: item.taskID)?.reviewActionIntentID == intentID else { throw CancellationError() }
                        }
                    )
                }
                try markDelivery(reviewID: reviewID, intentID: intentID, state: .delivered)
            }
            return
        }
        throw CancellationError()
    }

    private func markDelivery(reviewID: UUID, intentID: UUID, state: CoordinatorReviewAction.DeliveryState, message: String? = nil) throws {
        guard let item = store.item(id: reviewID), item.userAction?.intentID == intentID else { throw CancellationError() }
        try store.update(id: reviewID, expectedRevision: item.revision) {
            $0.userAction?.deliveryState = state
            $0.userAction?.updatedAt = self.now()
            if state == .delivered { $0.userAction?.deliveredAt = self.now() }
            $0.userAction?.deliveryDetail = message
        }
        if state == .failed { try clearLegacyMergeStatus(taskID: item.taskID, intentID: intentID) }
    }

    private func clearLegacyMergeStatus(taskID: UUID, intentID: UUID) throws {
        guard let tasks, tasks.records.record(id: taskID)?.reviewActionIntentID == intentID else { return }
        // Keep the intent pointer so a later CLI command still checks the
        // approval. The legacy "checking merge" flag must not imply delivery.
        try tasks.saveMergeState(taskID: taskID) { $0.mergeRequestedAt = nil }
    }

    private func observe(_ entries: [String: PullRequestStateCache.Entry]) {
        for (url, entry) in entries {
            if let link = WorkspacePullRequestLink(annotationURL: url), let state = entry.state { observe(link: link, state: state) }
        }
    }

    private func observe(link: WorkspacePullRequestLink, state: TaskPullRequestState) {
        for item in store.items where item.pullRequestURL == link.url {
            let outcome: CoordinatorReviewObservedOutcome.State
            if let head = state.headSHA, head.lowercased() != item.headSHA.lowercased() { outcome = .headChanged }
            else if let base = item.baseRefName, let actualBase = state.baseRefName, base != actualBase { outcome = .headChanged }
            else {
                switch state.state {
                case .open: outcome = .open
                case .closed: outcome = .closed
                case .merged:
                    let destinationKnown = item.baseRefName == nil || state.baseRefName == item.baseRefName
                    outcome = state.headSHA != nil && destinationKnown ? .merged : .unknown
                }
            }
            guard item.observedOutcome.state != outcome || item.observedOutcome.headSHA != state.headSHA
                    || item.observedOutcome.baseRefName != state.baseRefName
                    || item.observedOutcome.mergeCommit != state.mergeCommit else { continue }
            do {
                try store.update(id: item.id, expectedRevision: item.revision) {
                    $0.observedOutcome = .init(state: outcome, headSHA: state.headSHA, baseRefName: state.baseRefName, mergeCommit: state.mergeCommit, observedAt: self.now())
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
