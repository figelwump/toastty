import RemoteProtocol
import Foundation
import Testing
@testable import CoreState

struct RemoteConversationProjectionStoreTests {
    static let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
    static let otherConversationID = RemoteConversationID(rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!)
    static let bindingID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    static let workspaceID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    static let panelID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    static let startDate = Date(timeIntervalSince1970: 1_786_000_000)

    static func makeStore() -> RemoteConversationProjectionStore {
        let store = RemoteConversationProjectionStore()
        store.registerConversation(
            conversationID,
            descriptor: RemoteConversationProjectionStore.ConversationDescriptor(
                provider: .codex,
                title: "Sync job work",
                placement: RemoteConversationPlacement(workspaceID: workspaceID, panelID: panelID),
                cwd: "/tmp/demo"
            ),
            bindingID: bindingID,
            at: startDate
        )
        return store
    }

    static func ingestBasicSession(into store: RemoteConversationProjectionStore) {
        let observations = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.basicSession).observations
        store.ingest(observations, for: conversationID)
    }

    @Test func sessionListReflectsRegistrationAndState() {
        let store = Self.makeStore()
        Self.ingestBasicSession(into: store)

        let snapshot = store.sessionList(at: Self.startDate.addingTimeInterval(100))
        #expect(snapshot.projectionRunID == store.runID)
        #expect(snapshot.conversations.count == 1)

        let summary = snapshot.conversations[0]
        #expect(summary.conversationID == Self.conversationID)
        #expect(summary.provider == .codex)
        #expect(summary.title == "Sync job work")
        #expect(summary.placement.workspaceID == Self.workspaceID)
        #expect(summary.placement.panelID == Self.panelID)
        #expect(summary.state == .awaitingInput)
        #expect(summary.inputAvailability.allowsRemoteSend)
        #expect(summary.latestSequence > 0)
        #expect(summary.projectionGeneration == 0)
    }

    @Test func pagingWalksTheFullEventLog() {
        let store = Self.makeStore()
        Self.ingestBasicSession(into: store)

        var collected: [ConversationEvent] = []
        var cursor: ConversationEventCursor?
        var iterations = 0
        while iterations < 100 {
            iterations += 1
            guard case .page(let page) = store.conversationEvents(
                for: Self.conversationID,
                after: cursor,
                limit: 3
            ) else {
                Issue.record("Expected a page")
                return
            }
            collected.append(contentsOf: page.events)
            guard page.hasMore, let next = page.continuationCursor else { break }
            cursor = next
        }

        guard case .page(let fullPage) = store.conversationEvents(
            for: Self.conversationID,
            after: nil,
            limit: RemoteConversationProjectionStore.defaultPageLimit
        ) else {
            Issue.record("Expected full page")
            return
        }
        #expect(collected == fullPage.events)
        #expect(collected.map(\.sequence) == Array(1...UInt64(collected.count)))
    }

    @Test func backwardPagingOpensAtTailAndWalksToRetainedHead() {
        let store = Self.makeStore()
        Self.ingestBasicSession(into: store)

        guard case .page(let fullPage) = store.conversationEvents(
            for: Self.conversationID,
            after: nil,
            limit: RemoteConversationProjectionStore.defaultPageLimit
        ), case .page(let tailPage) = store.conversationEvents(
            for: Self.conversationID,
            before: nil,
            limit: 3
        ) else {
            Issue.record("Expected forward and tail pages")
            return
        }
        #expect(tailPage.events == Array(fullPage.events.suffix(3)))
        #expect(tailPage.events.map(\.sequence) == tailPage.events.map(\.sequence).sorted())

        var collected = tailPage.events
        var boundary = tailPage.events.first?.sequence
        var iterations = 0
        while let beforeSequence = boundary, iterations < 100 {
            iterations += 1
            let cursor = ConversationEventBackwardCursor(
                projectionRunID: tailPage.projectionRunID,
                projectionGeneration: tailPage.projectionGeneration,
                beforeSequence: beforeSequence
            )
            guard case .page(let page) = store.conversationEvents(
                for: Self.conversationID,
                before: cursor,
                limit: 3
            ) else {
                Issue.record("Expected backward page")
                return
            }
            guard page.events.isEmpty == false else { break }
            collected.insert(contentsOf: page.events, at: 0)
            boundary = page.events.first?.sequence
        }

        #expect(collected == fullPage.events)
        #expect(Set(collected.map(\.sequence)).count == collected.count)
    }

    @Test func backwardPagingValidatesProjectionAndExclusiveBoundary() {
        let store = Self.makeStore()
        Self.ingestBasicSession(into: store)
        guard case .page(let tailPage) = store.conversationEvents(
            for: Self.conversationID,
            before: nil,
            limit: 3
        ), let firstAvailable = tailPage.firstAvailableSequence else {
            Issue.record("Expected tail page metadata")
            return
        }

        let atHead = ConversationEventBackwardCursor(
            projectionRunID: tailPage.projectionRunID,
            projectionGeneration: tailPage.projectionGeneration,
            beforeSequence: firstAvailable
        )
        guard case .page(let emptyPage) = store.conversationEvents(
            for: Self.conversationID,
            before: atHead,
            limit: 3
        ) else {
            Issue.record("Expected empty head page")
            return
        }
        #expect(emptyPage.events.isEmpty)

        let immediatelyAfterTail = ConversationEventBackwardCursor(
            projectionRunID: tailPage.projectionRunID,
            projectionGeneration: tailPage.projectionGeneration,
            beforeSequence: tailPage.latestSequence + 1
        )
        guard case .page(let pageThroughTail) = store.conversationEvents(
            for: Self.conversationID,
            before: immediatelyAfterTail,
            limit: 3
        ) else {
            Issue.record("Expected the exclusive tail boundary to remain valid")
            return
        }
        #expect(pageThroughTail.events == tailPage.events)

        let stale = ConversationEventBackwardCursor(
            projectionRunID: RemoteProjectionRunID(),
            projectionGeneration: tailPage.projectionGeneration,
            beforeSequence: firstAvailable
        )
        #expect(store.conversationEvents(
            for: Self.conversationID,
            before: stale,
            limit: 3
        ) == .resnapshotRequired)

        let staleGeneration = ConversationEventBackwardCursor(
            projectionRunID: tailPage.projectionRunID,
            projectionGeneration: tailPage.projectionGeneration + 1,
            beforeSequence: firstAvailable
        )
        #expect(store.conversationEvents(
            for: Self.conversationID,
            before: staleGeneration,
            limit: 3
        ) == .resnapshotRequired)

        let invalidBoundary = ConversationEventBackwardCursor(
            projectionRunID: tailPage.projectionRunID,
            projectionGeneration: tailPage.projectionGeneration,
            beforeSequence: tailPage.latestSequence + 2
        )
        #expect(store.conversationEvents(
            for: Self.conversationID,
            before: invalidBoundary,
            limit: 3
        ) == .invalidRequest)
    }

    @Test func staleCursorsRequireResnapshot() {
        let store = Self.makeStore()
        Self.ingestBasicSession(into: store)

        let foreignRunCursor = ConversationEventCursor(
            projectionRunID: RemoteProjectionRunID(),
            projectionGeneration: 0,
            afterSequence: 0
        )
        #expect(store.conversationEvents(for: Self.conversationID, after: foreignRunCursor, limit: 10) == .resnapshotRequired)

        let staleGenerationCursor = ConversationEventCursor(
            projectionRunID: store.runID,
            projectionGeneration: 5,
            afterSequence: 0
        )
        #expect(store.conversationEvents(for: Self.conversationID, after: staleGenerationCursor, limit: 10) == .resnapshotRequired)

        #expect(store.conversationEvents(for: Self.otherConversationID, after: nil, limit: 10) == .conversationNotFound)
    }

    @Test func forcedResnapshotBumpsGenerationAndInvalidatesOldCursor() {
        let store = Self.makeStore()
        Self.ingestBasicSession(into: store)

        guard case .page(let page) = store.conversationEvents(for: Self.conversationID, after: nil, limit: 5),
              let cursor = page.continuationCursor else {
            Issue.record("Expected an initial page with a continuation")
            return
        }

        store.forceResnapshot(
            for: Self.conversationID,
            bindingID: Self.bindingID,
            at: Self.startDate.addingTimeInterval(500)
        )
        #expect(store.conversationEvents(for: Self.conversationID, after: cursor, limit: 5) == .resnapshotRequired)

        // Re-ingest after the rewrite; the fresh generation serves pages again.
        Self.ingestBasicSession(into: store)
        guard case .page(let freshPage) = store.conversationEvents(for: Self.conversationID, after: nil, limit: 100) else {
            Issue.record("Expected a fresh page")
            return
        }
        #expect(freshPage.projectionGeneration == 1)
        #expect(freshPage.events.contains { $0.kind == .userMessage })

        let summary = store.sessionList(at: Self.startDate.addingTimeInterval(600)).conversations[0]
        #expect(summary.projectionGeneration == 1)
    }

    @Test func conversationIdentitySurvivesResume() {
        let store = Self.makeStore()
        Self.ingestBasicSession(into: store)
        let sequenceBeforeResume = store.sessionList(at: Self.startDate).conversations[0].latestSequence

        store.noteBinding(
            for: Self.conversationID,
            reason: .runtimeResumed,
            providerSessionID: CodexRolloutFixtures.sessionID,
            bindingID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            at: Self.startDate.addingTimeInterval(7200)
        )
        let resumeObservations = CodexRolloutTranscriptParser
            .parseContents(CodexRolloutFixtures.basicSession + CodexRolloutFixtures.resumeContinuation)
            .observations
        store.ingest(resumeObservations, for: Self.conversationID)

        let snapshot = store.sessionList(at: Self.startDate.addingTimeInterval(7300))
        #expect(snapshot.conversations.count == 1)
        let summary = snapshot.conversations[0]
        #expect(summary.conversationID == Self.conversationID)
        #expect(summary.latestSequence > sequenceBeforeResume)
        #expect(summary.state == .awaitingInput)

        guard case .page(let page) = store.conversationEvents(for: Self.conversationID, after: nil, limit: 200) else {
            Issue.record("Expected a page")
            return
        }
        let bindingEvents = page.events.filter { $0.kind == .sessionBindingChanged }
        #expect(bindingEvents.count == 1)
        let userMessages = page.events.filter { $0.kind == .userMessage }
        // 2 from the original session + 2 "yes" turns after resume; the
        // re-parsed prefix deduplicates.
        #expect(userMessages.count == 4)
    }

    @Test func snapshotExposesPendingInteractions() {
        let store = Self.makeStore()
        let observations = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.approvalSession).observations
        var prefix: [ProviderTranscriptObservation] = []
        for observation in observations {
            prefix.append(observation)
            if case .interactionPresented = observation.payload { break }
        }
        store.ingest(prefix, for: Self.conversationID)

        let snapshot = store.conversationSnapshot(for: Self.conversationID, at: Self.startDate.addingTimeInterval(60))
        #expect(snapshot?.pendingInteractions.count == 1)
        #expect(snapshot?.summary.state == .awaitingInput)
        #expect(snapshot?.summary.inputAvailability.allowsRemoteSend == false)
    }

    @Test func removingConversationDeletesItsCache() {
        let store = Self.makeStore()
        Self.ingestBasicSession(into: store)
        store.removeConversation(Self.conversationID)

        #expect(store.sessionList(at: Self.startDate).conversations.isEmpty)
        #expect(store.conversationEvents(for: Self.conversationID, after: nil, limit: 10) == .conversationNotFound)
        #expect(store.conversationSnapshot(for: Self.conversationID, at: Self.startDate) == nil)
    }

    @Test func boundedProjectionRequiresResnapshotForAgedOutCursor() {
        let store = RemoteConversationProjectionStore(
            eventRetentionLimit: 3,
            fingerprintRetentionLimit: 4
        )
        store.registerConversation(
            Self.conversationID,
            descriptor: RemoteConversationProjectionStore.ConversationDescriptor(
                provider: .codex,
                title: "Bounded",
                placement: RemoteConversationPlacement(panelID: Self.panelID)
            ),
            bindingID: Self.bindingID,
            at: Self.startDate
        )

        for index in 0..<12 {
            store.ingest(
                [ProviderTranscriptObservation(
                    timestamp: Self.startDate.addingTimeInterval(Double(index)),
                    fingerprint: "bounded-\(index)",
                    payload: .contextCompacted
                )],
                for: Self.conversationID
            )
            store.noteBinding(
                for: Self.conversationID,
                reason: .runtimeResumed,
                bindingID: UUID(),
                at: Self.startDate.addingTimeInterval(Double(index + 1))
            )
        }

        guard case .page(let retainedPage) = store.conversationEvents(
            for: Self.conversationID,
            after: nil,
            limit: 200
        ) else {
            Issue.record("Expected retained page")
            return
        }
        #expect(retainedPage.historyTruncated == true)
        #expect((retainedPage.firstAvailableSequence ?? 0) > 1)
        #expect(retainedPage.events.count <= 4)
        #expect((store.projectorState(for: Self.conversationID)?.seenFingerprintCountForTesting ?? 0) <= 5)

        let agedOutCursor = ConversationEventCursor(
            projectionRunID: store.runID,
            projectionGeneration: retainedPage.projectionGeneration,
            afterSequence: 0
        )
        #expect(store.conversationEvents(
            for: Self.conversationID,
            after: agedOutCursor,
            limit: 3
        ) == .resnapshotRequired)
    }

    @Test func removingAndReregisteringConversationAdvancesGeneration() {
        let store = Self.makeStore()
        let initialGeneration = store.projectorState(for: Self.conversationID)?.generation
        store.removeConversation(Self.conversationID)
        store.registerConversation(
            Self.conversationID,
            descriptor: RemoteConversationProjectionStore.ConversationDescriptor(provider: .codex, title: "Rebound"),
            bindingID: UUID(),
            at: Self.startDate.addingTimeInterval(1)
        )
        #expect(store.projectorState(for: Self.conversationID)?.generation == (initialGeneration ?? 0) + 1)
    }

    @Test func identicalInputsRebuildIdenticalEvents() {
        func buildEvents() -> [ConversationEvent] {
            let store = Self.makeStore()
            Self.ingestBasicSession(into: store)
            guard case .page(let page) = store.conversationEvents(for: Self.conversationID, after: nil, limit: 200) else {
                return []
            }
            return page.events
        }
        let first = buildEvents()
        let second = buildEvents()
        #expect(first.isEmpty == false)
        #expect(first == second)
    }
}
