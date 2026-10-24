import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct CoordinatorReviewStoreTests {
    // Persistence failures must leave both memory and disk unchanged. A new
    // head must not inherit approval, and evidence cannot depend on a worktree.
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-reviews-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ root: URL) -> CoordinatorReviewStore {
        CoordinatorReviewStore(
            fileURL: root.appendingPathComponent("reviews.json"),
            evidenceDirectoryURL: root.appendingPathComponent("evidence")
        )
    }

    private func item(taskID: UUID = UUID(), head: String = String(repeating: "a", count: 40), baseRefName: String? = nil) -> CoordinatorReviewItem {
        CoordinatorReviewItem(
            taskID: taskID, taskTitle: "Review queue", projectRoot: "/tmp/review-source-worktree",
            repository: "owner/project", pullRequestURL: "https://github.com/owner/project/pull/12", headSHA: head,
            baseRefName: baseRefName,
            brief: .init(behaviorChange: "Persist review decisions.", decisionNeeded: "Approve merge.", recommendation: "Review the evidence."),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    @Test func restartRetainsBriefActionAndSeparateObservedOutcome() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = store(root)
        let published = try original.upsertPublication(item())
        let accepted = try original.update(id: published.id, expectedRevision: published.revision) {
            $0.userAction = .init(kind: .merge, approvedHeadSHA: $0.headSHA, agentOutcome: .init(state: .merged))
        }
        let restarted = store(root)
        #expect(restarted.loadError == nil)
        #expect(restarted.item(id: published.id) == accepted)
        #expect(restarted.item(id: published.id)?.observedOutcome.state == .unknown)
    }

    @Test func duplicatePublicationKeepsIdentityAndAcceptedBrief() throws {
        let value = item()
        let store = CoordinatorReviewStore.inMemory()
        let first = try store.upsertPublication(value)
        #expect(try store.upsertPublication(item(taskID: value.taskID)).id == first.id)
        #expect(store.items.count == 1)
        let accepted = try store.update(id: first.id, expectedRevision: first.revision) {
            $0.userAction = .init(kind: .merge, approvedHeadSHA: $0.headSHA)
        }
        #expect(try store.upsertPublication(value) == accepted)
        var changed = value
        changed.brief.behaviorChange = "A materially different explanation."
        #expect(throws: CoordinatorReviewStore.StoreError.self) { try store.upsertPublication(changed) }
        #expect(store.item(id: first.id) == accepted)
    }

    @Test func newHeadCreatesIndependentReviewAndRetainsOldApproval() throws {
        let store = CoordinatorReviewStore.inMemory()
        let first = try store.upsertPublication(item())
        let accepted = try store.update(id: first.id, expectedRevision: first.revision) {
            $0.userAction = .init(kind: .merge, approvedHeadSHA: $0.headSHA)
        }
        let next = try store.upsertPublication(item(taskID: first.taskID, head: String(repeating: "b", count: 40)))
        #expect(next.id != first.id)
        #expect(next.userAction == nil)
        #expect(store.item(id: first.id)?.userAction == accepted.userAction)
        #expect(store.item(id: first.id)?.observedOutcome.state == .unknown)
        #expect(store.item(id: first.id)?.revision == accepted.revision)
    }

    @Test func revisionMismatchCannotOverwriteAUserDecision() throws {
        let store = CoordinatorReviewStore.inMemory()
        let first = try store.upsertPublication(item())
        let accepted = try store.update(id: first.id, expectedRevision: first.revision) {
            $0.userAction = .init(kind: .changesRequested, approvedHeadSHA: $0.headSHA, feedback: "Add coverage.")
        }
        #expect(throws: CoordinatorReviewStore.StoreError.self) {
            try store.update(id: first.id, expectedRevision: first.revision) { $0.brief.recommendation = "Merge." }
        }
        #expect(store.item(id: first.id) == accepted)
    }

    @Test func corruptStoreRemainsVisibleAndCannotBeOverwritten() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reviews.json")
        let corrupt = Data("{ broken json".utf8)
        try corrupt.write(to: file)
        let store = store(root)
        #expect(store.loadError != nil)
        #expect(throws: CoordinatorReviewStore.StoreError.self) { try store.upsertPublication(item()) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func failedAtomicWriteDoesNotPublishTheChange() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let store = CoordinatorReviewStore(fileURL: blocked.appendingPathComponent("reviews.json"))
        #expect(throws: (any Error).self) { try store.upsertPublication(item()) }
        #expect(store.items.isEmpty)
        #expect(try Data(contentsOf: blocked) == Data("file".utf8))
    }

    @Test func failedUpdateRetainsThePersistedDecisionAndRevision() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let store = self.store(state)
        let first = try store.upsertPublication(item())
        let accepted = try store.update(id: first.id, expectedRevision: first.revision) {
            $0.userAction = .init(kind: .merge, approvedHeadSHA: $0.headSHA)
        }
        let retainedState = root.appendingPathComponent("retained-state")
        try FileManager.default.moveItem(at: state, to: retainedState)
        try Data("blocks directory creation".utf8).write(to: state)
        #expect(throws: (any Error).self) {
            try store.update(id: first.id, expectedRevision: accepted.revision) {
                $0.userAction?.deliveryState = .delivered
            }
        }
        #expect(store.item(id: first.id) == accepted)
        #expect(self.store(retainedState).item(id: first.id) == accepted)
    }

    @Test func evidenceCopiesSurviveSourceRemovalAndRestart() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source-report.html")
        let bytes = Data("<p>Verified behavior</p>".utf8)
        try bytes.write(to: source)
        var value = item()
        value.brief.evidence = [.init(kind: .report, label: "Report")]
        let store = store(root)
        let saved = try store.upsertPublication(value, evidenceFiles: [.init(evidenceIndex: 0, fileURL: source)])
        try FileManager.default.removeItem(at: source)
        let restarted = self.store(root)
        let evidence = try #require(restarted.item(id: saved.id)?.brief.evidence.first)
        let managed = try #require(restarted.managedEvidenceURL(for: evidence))
        #expect(try Data(contentsOf: managed) == bytes)
        #expect(!managed.path.contains("source-report"))
    }

    @Test func evidenceRejectsTraversalSymlinksAndOversizeFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("evidence".utf8).write(to: source)
        let symlink = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        let large = root.appendingPathComponent("large.txt")
        try Data(repeating: 0, count: CoordinatorReviewStore.maximumEvidenceFileBytes + 1).write(to: large)
        var value = item()
        value.brief.evidence = [.init(kind: .log, label: "Evidence")]
        let store = store(root)
        for file in [symlink, large, root.appendingPathComponent("../\(root.lastPathComponent)/source.txt")] {
            #expect(throws: (any Error).self) {
                try store.upsertPublication(value, evidenceFiles: [.init(evidenceIndex: 0, fileURL: file)])
            }
        }
        #expect(store.items.isEmpty)
    }

    @Test func failedSnapshotWriteRemovesOnlyTheNewEvidenceCopies() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.txt")
        try Data("verified".utf8).write(to: source)
        var value = item()
        value.brief.evidence = [.init(kind: .report, label: "Report")]
        let store = store(root)
        let first = try store.upsertPublication(value, evidenceFiles: [.init(evidenceIndex: 0, fileURL: source)])
        let savedURL = try #require(store.managedEvidenceURL(for: first.brief.evidence[0]))
        let snapshot = root.appendingPathComponent("reviews.json")
        try FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
        var next = item()
        next.brief.evidence = [.init(kind: .report, label: "New report")]
        #expect(throws: (any Error).self) {
            try store.upsertPublication(next, evidenceFiles: [.init(evidenceIndex: 0, fileURL: source)])
        }
        #expect(store.items == [first])
        #expect(try Data(contentsOf: savedURL) == Data("verified".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("evidence").path).count == 1)
    }

    @Test func evidenceCannotUseASymlinkStorageDirectoryOrAgentManagedName() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("evidence")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let source = root.appendingPathComponent("source.txt")
        try Data("verified".utf8).write(to: source)
        let store = store(root)
        var value = item()
        value.brief.evidence = [.init(kind: .report, label: "Report")]
        #expect(throws: (any Error).self) {
            try store.upsertPublication(value, evidenceFiles: [.init(evidenceIndex: 0, fileURL: source)])
        }
        value.brief.evidence[0].managedFileName = UUID().uuidString + ".txt"
        #expect(throws: CoordinatorReviewStore.StoreError.self) { try store.upsertPublication(value) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func configuredRuntimeHomeInsideProjectCheckoutRetainsCopiedEvidence() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceWorktree = root.appendingPathComponent("task-worktree")
        try FileManager.default.createDirectory(at: sourceWorktree, withIntermediateDirectories: false)
        let source = sourceWorktree.appendingPathComponent("report.txt")
        let bytes = Data("Verified in a disposable task worktree.".utf8)
        try bytes.write(to: source)
        let runtimeHome = root.appendingPathComponent("artifacts/runtime-home")
        let original = item()
        var value = CoordinatorReviewItem(
            taskID: original.taskID, taskTitle: original.taskTitle, projectRoot: root.path,
            repository: original.repository, pullRequestURL: original.pullRequestURL,
            headSHA: original.headSHA, brief: original.brief
        )
        value.brief.evidence = [.init(kind: .report, label: "Report")]
        let store = store(runtimeHome)
        let saved = try store.upsertPublication(value, evidenceFiles: [.init(evidenceIndex: 0, fileURL: source)])
        try FileManager.default.removeItem(at: sourceWorktree)
        let restarted = self.store(runtimeHome)
        #expect(restarted.loadError == nil)
        #expect(restarted.item(id: saved.id) == saved)
        let evidence = try #require(restarted.item(id: saved.id)?.brief.evidence.first)
        let managed = try #require(restarted.managedEvidenceURL(for: evidence))
        #expect(managed.path.hasPrefix(runtimeHome.path + "/"))
        #expect(try Data(contentsOf: managed) == bytes)
    }

    @Test func identicalEvidenceReplayKeepsRevisionAndCopyBeforeAndAfterDecision() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source-report.txt")
        try Data("verified behavior".utf8).write(to: source)
        var publication = item()
        publication.brief.evidence = [.init(kind: .report, label: "Report", excerpt: "Tests passed.")]
        let store = store(root)
        let files = [CoordinatorReviewStore.EvidenceFile(evidenceIndex: 0, fileURL: source)]
        let first = try store.upsertPublication(publication, evidenceFiles: files)
        #expect(try store.upsertPublication(publication, evidenceFiles: files) == first)
        #expect(try store.upsertPublication(publication) == first)
        let accepted = try store.update(id: first.id, expectedRevision: first.revision) {
            $0.userAction = .init(kind: .merge, approvedHeadSHA: $0.headSHA)
        }
        #expect(try store.upsertPublication(publication, evidenceFiles: files) == accepted)
        #expect(try store.upsertPublication(publication) == accepted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("evidence").path).count == 1)
        var forged = publication
        forged.brief.evidence[0].managedFileName = first.brief.evidence[0].managedFileName
        #expect(throws: CoordinatorReviewStore.StoreError.self) { try store.upsertPublication(forged) }
    }

    @Test func changedAcceptedEvidenceCannotReplaceTheReviewedCopy() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source-report.txt")
        let bytes = Data("reviewed evidence".utf8)
        try bytes.write(to: source)
        var publication = item()
        publication.brief.evidence = [.init(kind: .report, label: "Report")]
        let store = store(root)
        let files = [CoordinatorReviewStore.EvidenceFile(evidenceIndex: 0, fileURL: source)]
        let first = try store.upsertPublication(publication, evidenceFiles: files)
        let managed = try #require(store.managedEvidenceURL(for: first.brief.evidence[0]))
        let accepted = try store.update(id: first.id, expectedRevision: first.revision) {
            $0.userAction = .init(kind: .merge, approvedHeadSHA: $0.headSHA)
        }
        try Data("changed after review".utf8).write(to: source)
        #expect(throws: CoordinatorReviewStore.StoreError.acceptedPublicationConflict(first.id)) {
            try store.upsertPublication(publication, evidenceFiles: files)
        }
        #expect(store.item(id: first.id) == accepted)
        #expect(try Data(contentsOf: managed) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("evidence").path).count == 1)
    }

    @Test func missingEvidenceDoesNotBlockObservationOrMetadataReplay() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("verified".utf8).write(to: source)
        var publication = item()
        publication.brief.evidence = [.init(kind: .report, label: "Report")]
        let store = store(root)
        let first = try store.upsertPublication(publication, evidenceFiles: [.init(evidenceIndex: 0, fileURL: source)])
        let accepted = try store.update(id: first.id, expectedRevision: first.revision) {
            $0.userAction = .init(kind: .merge, approvedHeadSHA: $0.headSHA)
        }
        try FileManager.default.removeItem(at: #require(store.managedEvidenceURL(for: first.brief.evidence[0])))
        let observed = try store.update(id: first.id, expectedRevision: accepted.revision) {
            $0.userAction?.deliveryState = .delivered
            $0.observedOutcome = .init(state: .merged, headSHA: $0.headSHA, observedAt: Date())
        }
        #expect(observed.observedOutcome.state == .merged)
        #expect(store.managedEvidenceURL(for: observed.brief.evidence[0]) == nil)
        #expect(try store.upsertPublication(publication) == observed)
        #expect(self.store(root).item(id: observed.id) == observed)
    }

    @Test func nativeUpdateCannotChangeAnUnacceptedBrief() throws {
        let store = CoordinatorReviewStore.inMemory()
        let first = try store.upsertPublication(item())
        #expect(throws: CoordinatorReviewStore.StoreError.self) {
            try store.update(id: first.id, expectedRevision: first.revision) { $0.brief.behaviorChange = "Replaced by a native transaction." }
        }
        #expect(store.item(id: first.id) == first)
    }

    @Test func differentBaseCreatesIndependentReviewAndInvalidatesTheQueueMatch() throws {
        let store = CoordinatorReviewStore.inMemory()
        let first = try store.upsertPublication(item(baseRefName: "main"))
        var facts = CoordinatorReviewTaskFacts(
            taskID: first.taskID, taskTitle: first.taskTitle, projectRoot: first.projectRoot,
            pullRequestURL: first.pullRequestURL, headSHA: first.headSHA, baseRefName: "main", needsReview: true
        )
        store.reconcile([facts])
        #expect(store.queue.first?.review == first)
        facts.baseRefName = "release"
        store.reconcile([facts])
        #expect(store.queue.first?.needsBrief == true)
        let next = try store.upsertPublication(item(taskID: first.taskID, baseRefName: "release"))
        #expect(next.id != first.id)
        #expect(store.items.count == 2)
        #expect(store.queue.first?.review == next)
        #expect(next.userAction == nil)
    }

    @Test func replacingAnActionRetainsFeedbackAndDeliveryUncertaintyAcrossRestart() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(root)
        let first = try store.upsertPublication(item(baseRefName: "main"))
        let requested = try store.update(id: first.id, expectedRevision: first.revision) {
            $0.userAction = .init(kind: .changesRequested, approvedHeadSHA: $0.headSHA,
                                 feedback: "Add coverage.", deliveryState: .uncertain, deliveryDetail: "Connection ended after send.",
                                 agentOutcome: .init(state: .blocked, message: "The agent needs a follow-up."))
        }
        let replaced = try store.update(id: first.id, expectedRevision: requested.revision) {
            $0.userAction = .init(kind: .merge, approvedHeadSHA: $0.headSHA)
        }
        #expect(replaced.actionHistory == [try #require(requested.userAction)])
        #expect(self.store(root).item(id: replaced.id) == replaced)
        #expect(throws: CoordinatorReviewStore.StoreError.self) {
            try store.update(id: first.id, expectedRevision: replaced.revision) { $0.actionHistory = [] }
        }
        var publication = item(taskID: first.taskID, baseRefName: "main")
        publication.actionHistory = replaced.actionHistory
        #expect(throws: CoordinatorReviewStore.StoreError.self) { try store.upsertPublication(publication) }
    }

    @Test func actionHistoryOverflowRefusesReplacementWithoutDroppingPriorActions() throws {
        let store = CoordinatorReviewStore.inMemory()
        var value = try store.upsertPublication(item())
        for _ in 0...CoordinatorReviewItem.maximumActionHistoryCount {
            value = try store.update(id: value.id, expectedRevision: value.revision) {
                $0.userAction = .init(kind: .merge, approvedHeadSHA: $0.headSHA)
            }
        }
        #expect(value.actionHistory?.count == CoordinatorReviewItem.maximumActionHistoryCount)
        #expect(throws: CoordinatorReviewStore.StoreError.self) {
            try store.update(id: value.id, expectedRevision: value.revision) {
                $0.userAction = .init(kind: .merge, approvedHeadSHA: $0.headSHA)
            }
        }
        #expect(store.item(id: value.id) == value)
    }

    @Test func queueWorksWithoutBriefsAndRefreshesAfterPublications() throws {
        let store = CoordinatorReviewStore.inMemory()
        let value = item()
        let facts = CoordinatorReviewTaskFacts(
            taskID: value.taskID, taskTitle: value.taskTitle, projectRoot: value.projectRoot,
            pullRequestURL: value.pullRequestURL, headSHA: value.headSHA, needsReview: true
        )
        store.reconcile([facts])
        #expect(store.queue.count == 1)
        #expect(store.queue.first?.needsBrief == true)
        let published = try store.upsertPublication(value)
        #expect(store.queue.first?.review == published)
        #expect(store.queue.first?.needsBrief == false)
        var changedHead = facts
        changedHead.headSHA = String(repeating: "b", count: 40)
        store.reconcile([changedHead])
        #expect(store.queue.first?.needsBrief == true)
    }

    @Test func priorityOverridePersistsAndPublicationsCannotReplaceIt() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(root)
        let first = try store.upsertPublication(item())
        let changed = try store.update(id: first.id, expectedRevision: first.revision) { $0.priorityOverride = .urgent }
        #expect(try store.upsertPublication(item(taskID: first.taskID)) == changed)
        let restarted = self.store(root)
        #expect(restarted.item(id: first.id)?.priorityOverride == .urgent)
        #expect(restarted.queue.isEmpty)
        var attemptedOverride = item(taskID: first.taskID)
        attemptedOverride.priorityOverride = .blocking
        #expect(throws: CoordinatorReviewStore.StoreError.self) { try store.upsertPublication(attemptedOverride) }
    }

    @Test func queueKeepsFailuresVisibleUntilAMergeIsObserved() throws {
        let store = CoordinatorReviewStore.inMemory()
        let first = try store.upsertPublication(item())
        let facts = CoordinatorReviewTaskFacts(
            taskID: first.taskID, taskTitle: first.taskTitle, projectRoot: first.projectRoot,
            pullRequestURL: first.pullRequestURL, headSHA: first.headSHA, needsReview: false
        )
        store.reconcile([facts])
        #expect(store.queue.isEmpty)
        let failed = try store.update(id: first.id, expectedRevision: first.revision) {
            $0.userAction = .init(kind: .merge, approvedHeadSHA: $0.headSHA, agentOutcome: .init(state: .failed))
        }
        #expect(store.queue.first?.review == failed)
        let reported = try store.update(id: first.id, expectedRevision: failed.revision) {
            $0.userAction?.agentOutcome = .init(state: .merged)
        }
        #expect(store.queue.first?.review == reported)
        try store.update(id: first.id, expectedRevision: reported.revision) {
            $0.observedOutcome = .init(state: .merged, headSHA: $0.headSHA, observedAt: Date())
        }
        #expect(store.queue.isEmpty)
    }

    @Test func queueOrdersByPriorityAndUserOverrideThenTitle() throws {
        let store = CoordinatorReviewStore.inMemory()
        let first = try store.upsertPublication(item())
        let second = try store.upsertPublication(item())
        store.reconcile([
            .init(taskID: first.taskID, taskTitle: "A task", projectRoot: first.projectRoot,
                  pullRequestURL: first.pullRequestURL, headSHA: first.headSHA, needsReview: true),
            .init(taskID: second.taskID, taskTitle: "Z task", projectRoot: second.projectRoot,
                  pullRequestURL: second.pullRequestURL, headSHA: second.headSHA, needsReview: true, blocksOtherWork: true),
        ])
        #expect(store.queue.map(\.taskID) == [second.taskID, first.taskID])
        try store.update(id: first.id, expectedRevision: first.revision) { $0.priorityOverride = .urgent }
        #expect(store.queue.map(\.taskID) == [first.taskID, second.taskID])
    }
}
