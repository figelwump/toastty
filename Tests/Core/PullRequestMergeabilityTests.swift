import CoreState
import Testing

struct PullRequestMergeabilityTests {
    private func blocker(
        _ mergeState: PullRequestMergeability.MergeState?,
        checks: PullRequestMergeability.Checks? = nil,
        review: PullRequestMergeability.ReviewDecision? = nil,
        state: TaskPullRequestState.State = .open,
        isDraft: Bool = false
    ) -> PullRequestMergeBlocker? {
        TaskPullRequestState(
            state: state,
            isDraft: isDraft,
            mergeability: mergeState.map { PullRequestMergeability(mergeState: $0, checks: checks, reviewDecision: review) }
        ).mergeBlocker
    }

    @Test
    func onlyAMergeableOpenPullRequestIsReady() {
        #expect(blocker(.clean, checks: .passing) == nil)
        #expect(blocker(.hasHooks) == nil)
        // Not worked out yet, or not asked: nothing to warn about.
        #expect(blocker(.unknown) == nil)
        #expect(blocker(nil) == nil)
        // A merged or closed pull request has no Merge button to change.
        #expect(blocker(.dirty, state: .merged) == nil)
        #expect(blocker(.blocked, state: .closed, isDraft: true) == nil)
    }

    @Test
    func eachMergeStateNamesItsBlocker() {
        #expect(blocker(.draft) == .draft)
        #expect(blocker(.dirty) == .conflicts)
        #expect(blocker(.behind) == .behindBase)
        #expect(blocker(.unstable, checks: .failing) == .checksFailing)
        #expect(blocker(.unstable, checks: .running) == .checksRunning)
        // Unstable means a check did not pass, even if the rollup is empty.
        #expect(blocker(.unstable) == .checksFailing)
        #expect(blocker(.blocked) == .blocked)
    }

    @Test
    func aDraftWinsWhateverGitHubSaysAboutMerging() {
        #expect(blocker(.clean, isDraft: true) == .draft)
        #expect(blocker(.unknown, isDraft: true) == .draft)
        #expect(blocker(nil, isDraft: true) == .draft)
        #expect(blocker(.dirty, isDraft: true) == .draft)
    }

    @Test
    func aBlockedPullRequestNamesFailingChecksThenReviewsThenRunningChecks() {
        #expect(blocker(.blocked, checks: .failing, review: .reviewRequired) == .checksFailing)
        #expect(blocker(.blocked, checks: .running, review: .changesRequested) == .changesRequested)
        #expect(blocker(.blocked, checks: .running, review: .reviewRequired) == .reviewRequired)
        #expect(blocker(.blocked, checks: .running, review: .approved) == .checksRunning)
        #expect(blocker(.blocked, checks: .passing, review: .approved) == .blocked)
    }
}
