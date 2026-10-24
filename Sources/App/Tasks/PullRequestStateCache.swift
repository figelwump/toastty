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
        /// The last good answer; kept when a later request fails.
        var state: TaskPullRequestState?
        /// When the request behind `state` started.
        var answeredAt: Date?
        var lastError: String?
    }

    static let requestTimeout: TimeInterval = 30
    nonisolated static let viewFields = "state,isDraft,headRefOid,baseRefName,mergeCommit"
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
        entries[link.url]?.state
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
            self.inFlight[link.url] = nil
            if let state = Self.state(from: result) {
                self.store(state, for: link, observedAt: startedAt)
            } else {
                var entry = self.entries[link.url] ?? Entry()
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
        var entry = entries[link.url] ?? Entry()
        if let answeredAt = entry.answeredAt, answeredAt > observedAt {
            return
        }
        var state = state
        // While GitHub works out the merge state, as it does after a push,
        // keep the last known one so the Merge button does not flicker.
        if state.state == .open, state.mergeability?.isKnown != true,
           let known = entry.state?.mergeability, known.isKnown {
            state.mergeability = known
        }
        let changed = entry.state != state
        entry.state = state
        entry.answeredAt = observedAt
        entry.lastError = nil
        entries[link.url] = entry
        if changed {
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
            baseRefName: object["baseRefName"] as? String,
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
