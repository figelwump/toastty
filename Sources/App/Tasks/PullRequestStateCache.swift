import CoreState
import Foundation

/// GitHub's last answer for each task pull request, so a task's stage can be
/// worked out without waiting on `gh`. It only reports what it sees: merges
/// are still run, and cleaned up after, by `WorkspaceMergeCoordinator`.
///
/// Requests for the same pull request are merged into one, and an answer to
/// a request that started before the cached one is dropped, so a slow
/// answer cannot replace a newer state.
@MainActor
final class PullRequestStateCache: ObservableObject {
    struct Entry: Equatable {
        /// The last good answer for `task get` and alerts. Missing readiness
        /// fields keep the last reported checks for the same head commit.
        var answer: TaskPullRequestState?
        /// Distinguishes a fresh readiness answer from inherited check history.
        var readinessWasReported = false
        /// The last known readiness and its head, used only during a short
        /// grace period for that same commit.
        var knownState: TaskPullRequestState?
        var knownAt: Date?
        /// When the request behind `answer` started.
        var answeredAt: Date?
        /// Includes failed requests, so failures cannot cause a tight retry loop.
        var requestedAt: Date?
        var lastError: String?
    }

    static let requestTimeout: TimeInterval = 30
    static let settledRefreshInterval: TimeInterval = 120
    static let pendingRefreshInterval: TimeInterval = 15
    static let mergeabilityGracePeriod: TimeInterval = 30
    nonisolated static let viewFields = "state,isDraft,headRefOid,mergeCommit,baseRefName"
    /// Also whether the pull request is ready to merge, for the Merge
    /// button. `statusCheckRollup` only tells failing checks from running
    /// ones, but a token that cannot read checks fails the whole request, so
    /// a failed request asks again with `viewFields`.
    nonisolated static let readinessViewFields = viewFields + ",mergeStateStatus,reviewDecision,statusCheckRollup"

    @Published private(set) var entries: [String: Entry] = [:]
    /// Called with each answer that changes the cache.
    var answerObserver: ((WorkspacePullRequestLink, TaskPullRequestState) -> Void)?

    private let runner: any WorkspaceMergeCommandRunning
    private let directory: String
    private let now: () -> Date
    private var inFlight: [String: Task<Void, Never>] = [:]

    init(
        runner: any WorkspaceMergeCommandRunning,
        directory: String = NSHomeDirectory(),
        now: @escaping () -> Date = Date.init
    ) {
        self.runner = runner
        self.directory = directory
        self.now = now
    }

    func state(for link: WorkspacePullRequestLink) -> TaskPullRequestState? {
        guard let entry = entries[link.url], var state = entry.answer else { return nil }
        guard state.state == .open else { return state }
        if entry.readinessWasReported == false { state.mergeability = nil }
        if state.mergeability?.isKnown == true, entry.lastError == nil { return state }
        if let head = state.headSHA, let known = entry.knownState, known.headSHA == head,
           let knownAt = entry.knownAt, now().timeIntervalSince(knownAt) < Self.mergeabilityGracePeriod {
            state.mergeability = known.mergeability
        } else if entry.lastError != nil {
            // Keep the PR's lifecycle state, but stop presenting old readiness
            // as current after the grace period.
            state.mergeability = nil
        }
        return state
    }

    /// The last reported checks for this head, without the Merge button's
    /// smoothing. A field-limited reply is not evidence that checks cleared.
    func answer(for link: WorkspacePullRequestLink) -> TaskPullRequestState? {
        entries[link.url]?.answer
    }

    /// Called by the board's 15 second tick. Settled PRs need fewer requests;
    /// pending, unknown and failed answers are retried on the next tick.
    @discardableResult
    func refreshIfNeeded(_ link: WorkspacePullRequestLink) -> Task<Void, Never>? {
        if var entry = entries[link.url], let knownAt = entry.knownAt,
           now().timeIntervalSince(knownAt) >= Self.mergeabilityGracePeriod {
            // Publish expiry even if a slow request is still in flight, so
            // views stop displaying the previous readiness on this tick.
            entry.knownState = nil
            entry.knownAt = nil
            entries[link.url] = entry
        }
        let entry = entries[link.url]
        let answer = entry?.answer
        let needsFrequentRefresh = entry?.lastError != nil || answer == nil
            || (answer?.state == .open && (entry?.readinessWasReported != true
                || answer?.mergeability?.isKnown != true || answer?.mergeability?.checks == .running))
        let interval = needsFrequentRefresh ? Self.pendingRefreshInterval : Self.settledRefreshInterval
        if let requestedAt = entry?.requestedAt, now().timeIntervalSince(requestedAt) < interval {
            return nil
        }
        return refresh(link)
    }

    /// Whether a request for this pull request is running.
    func isRefreshing(_ link: WorkspacePullRequestLink) -> Bool {
        inFlight[link.url] != nil
    }

    /// Asks GitHub again, unless a request for this pull request is running.
    @discardableResult
    func refresh(_ link: WorkspacePullRequestLink) -> Task<Void, Never> {
        if let running = inFlight[link.url] {
            return running
        }
        let startedAt = now()
        let task = Task { [weak self, runner, directory] in
            // `gh pr view` with a full URL needs no checkout.
            var result = await runner.run(
                arguments: ["gh", "pr", "view", link.url, "--json", Self.readinessViewFields],
                directory: directory,
                timeout: Self.requestTimeout
            )
            if result.exitCode != 0 {
                result = await runner.run(
                    arguments: ["gh", "pr", "view", link.url, "--json", Self.viewFields],
                    directory: directory,
                    timeout: Self.requestTimeout
                )
            }
            guard let self else { return }
            defer { self.inFlight[link.url] = nil }
            if var state = Self.state(from: result) {
                if state.state == .merged,
                   let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                   let base = object["baseRefName"] as? String, base.isEmpty == false {
                    let repository = await runner.run(
                        arguments: ["gh", "repo", "view", link.repository, "--json", "defaultBranchRef"],
                        directory: directory,
                        timeout: Self.requestTimeout
                    )
                    if repository.exitCode == 0,
                       let info = try? JSONSerialization.jsonObject(with: Data(repository.stdout.utf8)) as? [String: Any],
                       let branch = (info["defaultBranchRef"] as? [String: Any])?["name"] as? String,
                       branch.isEmpty == false {
                        state.mergeTarget = TaskMergeTarget(baseBranch: base, releaseBranch: branch)
                    }
                }
                self.store(state, for: link, observedAt: startedAt)
            } else {
                var entry = self.entries[link.url] ?? Entry()
                if let answeredAt = entry.answeredAt, answeredAt > startedAt { return }
                entry.requestedAt = startedAt
                entry.lastError = result.problemSummary
                self.entries[link.url] = entry
            }
        }
        inFlight[link.url] = task
        return task
    }

    /// Records an answer, from this cache or from another caller that asked
    /// GitHub, such as the merge coordinator.
    func store(_ state: TaskPullRequestState, for link: WorkspacePullRequestLink, observedAt: Date) {
        let previous = self.state(for: link)
        var entry = entries[link.url] ?? Entry()
        if let answeredAt = entry.answeredAt, answeredAt > observedAt {
            return
        }
        var answer = state
        if answer.state == .merged, answer.mergeTarget == nil, entry.answer?.state == .merged {
            answer.mergeTarget = entry.answer?.mergeTarget
        }
        if answer.mergeability == nil, let head = answer.headSHA,
           let last = entry.answer, last.headSHA == head {
            answer.mergeability = last.mergeability
        }
        entry.answer = answer
        entry.readinessWasReported = state.mergeability != nil
        if state.state == .open, state.mergeability?.isKnown == true {
            entry.knownState = state
            entry.knownAt = observedAt
        } else if state.state != .open || state.headSHA == nil || entry.knownState?.headSHA != state.headSHA {
            entry.knownState = nil
            entry.knownAt = nil
        }
        entry.answeredAt = observedAt
        entry.requestedAt = max(entry.requestedAt ?? observedAt, observedAt)
        entry.lastError = nil
        entries[link.url] = entry
        if let state = self.state(for: link), previous != state {
            answerObserver?(link, state)
        }
    }

    /// Reads `gh pr view --json` with `viewFields` or `readinessViewFields`.
    nonisolated static func state(from result: WorkspaceMergeCommandResult) -> TaskPullRequestState? {
        guard result.exitCode == 0,
              let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let rawState = object["state"] as? String,
              let state = TaskPullRequestState.State(rawValue: rawState.lowercased()) else {
            return nil
        }
        let mergeCommit = (object["mergeCommit"] as? [String: Any])?["oid"] as? String
        return TaskPullRequestState(
            state: state,
            isDraft: object["isDraft"] as? Bool ?? false,
            headSHA: object["headRefOid"] as? String,
            mergeCommit: mergeCommit,
            mergeability: mergeability(from: object)
        )
    }

    /// `nil` when the answer has no `mergeStateStatus`. A value this build
    /// does not know reads as unknown, so it never blocks the Merge button.
    private nonisolated static func mergeability(from object: [String: Any]) -> PullRequestMergeability? {
        guard let rawMergeState = object["mergeStateStatus"] as? String else { return nil }
        let rawReview = (object["reviewDecision"] as? String)?.lowercased() ?? ""
        return PullRequestMergeability(
            mergeState: PullRequestMergeability.MergeState(rawValue: rawMergeState.lowercased()) ?? .unknown,
            checks: checks(from: object["statusCheckRollup"] as? [[String: Any]] ?? []),
            reviewDecision: PullRequestMergeability.ReviewDecision(rawValue: rawReview)
        )
    }

    /// Any check that finished without passing fails the rollup; otherwise
    /// any unfinished one keeps it running. Entries are check runs
    /// (`status`, `conclusion`) or commit statuses (`state`).
    private nonisolated static func checks(from rollup: [[String: Any]]) -> PullRequestMergeability.Checks? {
        guard rollup.isEmpty == false else { return nil }
        let passed: Set<String> = ["SUCCESS", "NEUTRAL", "SKIPPED"]
        var isRunning = false
        for check in rollup {
            if let state = check["state"] as? String {
                if state == "PENDING" || state == "EXPECTED" {
                    isRunning = true
                } else if state != "SUCCESS" {
                    return .failing
                }
            } else if (check["status"] as? String) != "COMPLETED" {
                isRunning = true
            } else if passed.contains(check["conclusion"] as? String ?? "") == false {
                return .failing
            }
        }
        return isRunning ? .running : .passing
    }
}
