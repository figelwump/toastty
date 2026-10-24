import CoreState
import Foundation
import Testing

struct CoordinatorReviewItemTests {
    // These records must reject ambiguous PR/head identities and oversized input.
    // An agent's reported merge must never become an observed GitHub merge.
    private func item() -> CoordinatorReviewItem {
        CoordinatorReviewItem(
            taskID: UUID(), taskTitle: "Review queue", projectRoot: "/tmp/project",
            repository: "owner/project", pullRequestURL: "https://github.com/owner/project/pull/12",
            headSHA: String(repeating: "a", count: 40),
            brief: CoordinatorReviewBrief(
                behaviorChange: "Review records survive restart.", decisionNeeded: "Approve this head.",
                verification: ["Store tests passed."], gaps: [], recommendation: "Merge after review."
            ), createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    @Test func recordsRoundTripWithDistinctReportedAndObservedOutcomes() throws {
        var value = item()
        value.userAction = CoordinatorReviewAction(
            kind: .merge, approvedHeadSHA: value.headSHA,
            agentOutcome: .init(state: .merged, message: "The agent reports that the PR merged."),
            requestedAt: value.createdAt
        )
        try value.validate()
        #expect(value.observedOutcome.state == .unknown)
        #expect(try JSONDecoder().decode(CoordinatorReviewItem.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func minimalAPIBriefUsesNativeDefaultsAndStillRequiresDecisionFields() throws {
        let minimal = Data(#"{"behaviorChange":"Persist reviews.","decisionNeeded":"Approve this head.","recommendation":"Review evidence."}"#.utf8)
        let brief = try JSONDecoder().decode(CoordinatorReviewBrief.self, from: minimal)
        try brief.validate()
        #expect(brief.verification.isEmpty)
        #expect(brief.gaps.isEmpty)
        #expect(brief.evidence.isEmpty)
        #expect(brief.priority == .ready)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CoordinatorReviewBrief.self, from: Data(#"{"behaviorChange":"Persist reviews."}"#.utf8))
        }
    }

    @Test func onlyFullCommitIDsAreAccepted() throws {
        #expect(CoordinatorReviewItem.isValidCommitID(String(repeating: "a", count: 40)))
        #expect(CoordinatorReviewItem.isValidCommitID(String(repeating: "B", count: 64)))
        #expect(!CoordinatorReviewItem.isValidCommitID("abcdef1"))
        #expect(!CoordinatorReviewItem.isValidCommitID(String(repeating: "z", count: 40)))
    }

    @Test func publicationRequiresCanonicalGitHubPRIdentity() throws {
        let original = item()
        for url in [
            "https://github.com/owner/project/pull/12/files",
            "https://github.com/owner/project/pull/12?x=1",
            "https://user@github.com/owner/project/pull/12",
            "https://github.com/owner/project/pull/0",
            "https://example.com/owner/project/pull/12",
        ] {
            let invalid = CoordinatorReviewItem(
                taskID: original.taskID, taskTitle: original.taskTitle, projectRoot: original.projectRoot,
                repository: original.repository, pullRequestURL: url, headSHA: original.headSHA,
                brief: original.brief, createdAt: original.createdAt
            )
            #expect(throws: CoordinatorReviewValidationError.self) { try invalid.validate() }
        }
    }

    @Test func requiredBriefFieldsAndPublishedLimitsAreEnforced() throws {
        var value = item()
        value.brief.decisionNeeded = " \n "
        #expect(throws: CoordinatorReviewValidationError.self) { try value.validate() }
        value = item()
        value.brief.verification = Array(repeating: "check", count: CoordinatorReviewBrief.maximumListCount + 1)
        #expect(throws: CoordinatorReviewValidationError.self) { try value.validate() }
        value = item()
        value.brief.behaviorChange = String(repeating: "x", count: CoordinatorReviewBrief.maximumTextLength + 1)
        #expect(throws: CoordinatorReviewValidationError.self) { try value.validate() }
        value = item()
        value.brief.evidence = [.init(kind: .report, label: "Report", managedFileName: "../report.html")]
        #expect(throws: CoordinatorReviewValidationError.self) { try value.validate() }
        value = item()
        value.brief.evidence = Array(repeating: .init(kind: .report, label: "Report"), count: CoordinatorReviewBrief.maximumEvidenceCount + 1)
        #expect(throws: CoordinatorReviewValidationError.self) { try value.validate() }
    }

    @Test func actionMustNameTheReviewedHead() throws {
        var value = item()
        value.userAction = .init(kind: .merge, approvedHeadSHA: String(repeating: "b", count: 40))
        #expect(throws: CoordinatorReviewValidationError.self) { try value.validate() }
    }

    @Test func queueUsesNativeUrgencyAndThenUserPriorityOverride() {
        let value = item()
        let facts = CoordinatorReviewTaskFacts(
            taskID: value.taskID, taskTitle: value.taskTitle, projectRoot: value.projectRoot,
            pullRequestURL: value.pullRequestURL, headSHA: value.headSHA, needsReview: true,
            isUrgent: true
        )
        #expect(CoordinatorReviewQueueEntry(facts: facts).needsBrief)
        #expect(CoordinatorReviewQueueEntry(facts: facts, review: value).effectivePriority == .urgent)
        var overridden = value
        overridden.priorityOverride = .ready
        #expect(CoordinatorReviewQueueEntry(facts: facts, review: overridden).effectivePriority == .ready)
    }

    @Test func baseRefIsOptionalButMustBeBoundedNonemptyAndWithoutWhitespaceOrControls() throws {
        let original = item()
        for base in ["", " ", "release branch", "release\nbranch", "release\u{7f}branch", String(repeating: "a", count: CoordinatorReviewItem.maximumBaseRefNameLength + 1)] {
            let invalid = CoordinatorReviewItem(
                taskID: original.taskID, taskTitle: original.taskTitle, projectRoot: original.projectRoot,
                repository: original.repository, pullRequestURL: original.pullRequestURL, headSHA: original.headSHA,
                baseRefName: base, brief: original.brief
            )
            #expect(throws: CoordinatorReviewValidationError.self) { try invalid.validate() }
        }
        try original.validate()
    }

    @Test func historicalRecordWithoutBaseOrActionHistoryStillDecodes() throws {
        let legacy = #"""
        {"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","revision":1,
         "taskID":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","taskTitle":"Review queue",
         "projectRoot":"/tmp/project","repository":"owner/project",
         "pullRequestURL":"https://github.com/owner/project/pull/12",
         "headSHA":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "brief":{"behaviorChange":"Persist reviews.","decisionNeeded":"Approve merge.","recommendation":"Review evidence."},
         "createdAt":0,"updatedAt":0,"observedOutcome":{"state":"unknown"}}
        """#
        let decoded = try JSONDecoder().decode(CoordinatorReviewItem.self, from: Data(legacy.utf8))
        try decoded.validate()
        #expect(decoded.baseRefName == nil)
        #expect(decoded.actionHistory == nil)
    }
}
