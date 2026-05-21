@testable import ToasttyApp
import CoreState
import Dispatch
import Foundation
import Testing

struct ScratchpadDocumentStoreTests {
    @Test
    func createAndReplaceDocumentPersistsRevisions() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let sessionLink = ScratchpadSessionLink(
            sessionID: "sess-doc",
            agent: .codex,
            sourcePanelID: UUID(),
            sourceWorkspaceID: UUID(),
            repoRoot: "/tmp/project",
            cwd: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 100)
        )

        let created = try fixture.store.createDocument(
            title: "Initial",
            content: "<h1>One</h1>",
            sessionLink: sessionLink,
            now: Date(timeIntervalSince1970: 200)
        )
        let updated = try fixture.store.replaceContent(
            documentID: created.documentID,
            title: "Updated",
            content: "<h1>Two</h1>",
            expectedRevision: 1,
            sessionLink: sessionLink,
            now: Date(timeIntervalSince1970: 300)
        )
        let loadedDocument = try fixture.store.load(documentID: created.documentID)
        let reloaded = try #require(loadedDocument)

        #expect(created.revision == 1)
        #expect(updated.revision == 2)
        #expect(updated.title == "Updated")
        #expect(updated.content == "<h1>Two</h1>")
        #expect(reloaded == updated)
    }

    @Test
    func updateSessionLinkPersistsWithoutChangingContentRevision() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: "Initial",
            content: "<p>One</p>",
            sessionLink: nil,
            now: Date(timeIntervalSince1970: 100)
        )
        let sessionLink = ScratchpadSessionLink(
            sessionID: "sess-rebound",
            agent: .claude,
            sourcePanelID: UUID(),
            sourceWorkspaceID: UUID(),
            repoRoot: "/tmp/project",
            cwd: "/tmp/project",
            displayTitle: "Claude",
            startedAt: Date(timeIntervalSince1970: 200)
        )

        let updated = try fixture.store.updateSessionLink(
            documentID: created.documentID,
            sessionLink: sessionLink,
            now: Date(timeIntervalSince1970: 300)
        )
        let loadedDocument = try fixture.store.load(documentID: created.documentID)
        let reloaded = try #require(loadedDocument)

        #expect(updated.revision == 1)
        #expect(updated.title == "Initial")
        #expect(updated.content == "<p>One</p>")
        #expect(updated.sessionLink == sessionLink)
        #expect(updated.updatedAt == Date(timeIntervalSince1970: 300))
        #expect(reloaded == updated)
    }

    @Test
    func staleExpectedRevisionIsRejected() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: nil,
            content: "first",
            sessionLink: nil
        )

        #expect(throws: ScratchpadDocumentStoreError.staleRevision(expectedRevision: 4, currentRevision: 1)) {
            try fixture.store.replaceContent(
                documentID: created.documentID,
                title: nil,
                content: "second",
                expectedRevision: 4,
                sessionLink: nil
            )
        }
    }

    @Test
    func oversizedContentIsRejectedBeforeWrite() throws {
        let fixture = try ScratchpadDocumentStoreFixture(maxContentBytes: 4)

        #expect(throws: ScratchpadDocumentStoreError.contentTooLarge(maxBytes: 4, actualBytes: 5)) {
            try fixture.store.createDocument(
                title: nil,
                content: "12345",
                sessionLink: nil
            )
        }
    }

    @Test
    func applyPatchReplacesUniqueTextAndPersistsRevision() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: "Patch me",
            content: "<main><h1>Old</h1><p>Body</p></main>",
            sessionLink: nil,
            now: Date(timeIntervalSince1970: 100)
        )
        let patch = try patchJSON([
            .init(oldText: "<h1>Old</h1>", newText: "<h1>New</h1>"),
        ])

        let outcome = try fixture.store.applyPatch(
            documentID: created.documentID,
            patchJSON: patch,
            expectedRevision: 1,
            sessionLink: nil,
            now: Date(timeIntervalSince1970: 200)
        )
        let reloaded = try #require(try fixture.store.load(documentID: created.documentID))

        #expect(outcome.documentID == created.documentID)
        #expect(outcome.previousRevision == 1)
        #expect(outcome.revision == 2)
        #expect(outcome.appliedEditCount == 1)
        #expect(outcome.document.content == "<main><h1>New</h1><p>Body</p></main>")
        #expect(outcome.document.updatedAt == Date(timeIntervalSince1970: 200))
        #expect(reloaded == outcome.document)
    }

    @Test
    func applyPatchUsesSequentialReplacementSemantics() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: nil,
            content: "alpha beta gamma",
            sessionLink: nil
        )
        let patch = try patchJSON([
            .init(oldText: "alpha beta", newText: "alpha"),
            .init(oldText: "alpha gamma", newText: "done"),
        ])

        let outcome = try fixture.store.applyPatch(
            documentID: created.documentID,
            patchJSON: patch,
            expectedRevision: 1,
            sessionLink: nil
        )

        #expect(outcome.document.content == "done")
        #expect(outcome.appliedEditCount == 2)
    }

    @Test
    func applyPatchAllowsEarlierReplacementToCreateLaterMatch() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: nil,
            content: "<p>A</p><p>C</p>",
            sessionLink: nil
        )
        let patch = try patchJSON([
            .init(oldText: "<p>A</p>", newText: "<p>A</p><p>B</p>"),
            .init(oldText: "<p>B</p><p>C</p>", newText: "<p>BC</p>"),
        ])

        let outcome = try fixture.store.applyPatch(
            documentID: created.documentID,
            patchJSON: patch,
            expectedRevision: 1,
            sessionLink: nil
        )

        #expect(outcome.document.content == "<p>A</p><p>BC</p>")
    }

    @Test
    func applyPatchHandlesOverlappingOrderedEdits() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: nil,
            content: "<p>abc</p>",
            sessionLink: nil
        )
        let patch = try patchJSON([
            .init(oldText: "abc", newText: "ab"),
            .init(oldText: "ab", newText: "AB"),
        ])

        let outcome = try fixture.store.applyPatch(
            documentID: created.documentID,
            patchJSON: patch,
            expectedRevision: 1,
            sessionLink: nil
        )

        #expect(outcome.document.content == "<p>AB</p>")
    }

    @Test
    func noOpPatchStillAdvancesRevision() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: nil,
            content: "<p>Same</p>",
            sessionLink: nil
        )
        let patch = try patchJSON([
            .init(oldText: "<p>Same</p>", newText: "<p>Same</p>"),
        ])

        let outcome = try fixture.store.applyPatch(
            documentID: created.documentID,
            patchJSON: patch,
            expectedRevision: 1,
            sessionLink: nil
        )

        #expect(outcome.revision == 2)
        #expect(outcome.document.content == "<p>Same</p>")
    }

    @Test
    func stalePatchExpectedRevisionIsRejected() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: nil,
            content: "first",
            sessionLink: nil
        )
        let patch = try patchJSON([
            .init(oldText: "first", newText: "second"),
        ])

        #expect(throws: ScratchpadDocumentStoreError.staleRevision(expectedRevision: 4, currentRevision: 1)) {
            try fixture.store.applyPatch(
                documentID: created.documentID,
                patchJSON: patch,
                expectedRevision: 4,
                sessionLink: nil
            )
        }
    }

    @Test
    func invalidPatchShapesAreRejectedBeforeWrite() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: nil,
            content: "first",
            sessionLink: nil
        )

        #expect(throws: ScratchpadDocumentStoreError.emptyPatch) {
            try fixture.store.applyPatch(
                documentID: created.documentID,
                patchJSON: #"{"replacements":[]}"#,
                expectedRevision: 1,
                sessionLink: nil
            )
        }
        do {
            _ = try fixture.store.applyPatch(
                documentID: created.documentID,
                patchJSON: #"{"replacements":[{"oldText":"first","newText":"second","extra":true}]}"#,
                expectedRevision: 1,
                sessionLink: nil
            )
            Issue.record("unknown patch fields should be rejected")
        } catch ScratchpadDocumentStoreError.invalidPatch(let reason) {
            #expect(reason.contains("unknown field(s): extra"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        let reloaded = try #require(try fixture.store.load(documentID: created.documentID))
        #expect(reloaded.revision == 1)
        #expect(reloaded.content == "first")
    }

    @Test
    func applyPatchRequiresByteExactMatchEvenWhenUnicodeEquivalent() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        // Content stores the precomposed form U+00F1 ("ñ").
        let created = try fixture.store.createDocument(
            title: nil,
            content: "ma\u{00F1}ana",
            sessionLink: nil
        )
        // Patch quotes the canonically equivalent decomposed form ("n" + U+0303).
        let patch = try patchJSON([
            .init(oldText: "man\u{0303}ana", newText: "morning"),
        ])

        #expect(throws: ScratchpadDocumentStoreError.oldTextNotFound(replacementIndex: 1)) {
            try fixture.store.applyPatch(
                documentID: created.documentID,
                patchJSON: patch,
                expectedRevision: 1,
                sessionLink: nil
            )
        }
        let reloaded = try #require(try fixture.store.load(documentID: created.documentID))
        #expect(reloaded.revision == 1)
        #expect(reloaded.content == "ma\u{00F1}ana")
    }

    @Test
    func emptyMissingAndDuplicateOldTextAreRejectedBeforeWrite() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: nil,
            content: "<p>one</p><p>two</p><p>two</p>",
            sessionLink: nil
        )

        #expect(throws: ScratchpadDocumentStoreError.emptyOldText(replacementIndex: 1)) {
            try fixture.store.applyPatch(
                documentID: created.documentID,
                patchJSON: try patchJSON([.init(oldText: "", newText: "x")]),
                expectedRevision: 1,
                sessionLink: nil
            )
        }
        #expect(throws: ScratchpadDocumentStoreError.oldTextNotFound(replacementIndex: 1)) {
            try fixture.store.applyPatch(
                documentID: created.documentID,
                patchJSON: try patchJSON([.init(oldText: "<p>missing</p>", newText: "x")]),
                expectedRevision: 1,
                sessionLink: nil
            )
        }
        #expect(throws: ScratchpadDocumentStoreError.oldTextNotUnique(replacementIndex: 1, matchCount: 2)) {
            try fixture.store.applyPatch(
                documentID: created.documentID,
                patchJSON: try patchJSON([.init(oldText: "<p>two</p>", newText: "x")]),
                expectedRevision: 1,
                sessionLink: nil
            )
        }
        let reloaded = try #require(try fixture.store.load(documentID: created.documentID))
        #expect(reloaded.revision == 1)
        #expect(reloaded.content == "<p>one</p><p>two</p><p>two</p>")
    }

    @Test
    func overlappingOldTextMatchesAreRejectedBeforeWrite() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: nil,
            content: "aaa",
            sessionLink: nil
        )

        #expect(throws: ScratchpadDocumentStoreError.oldTextNotUnique(replacementIndex: 1, matchCount: 2)) {
            try fixture.store.applyPatch(
                documentID: created.documentID,
                patchJSON: try patchJSON([.init(oldText: "aa", newText: "b")]),
                expectedRevision: 1,
                sessionLink: nil
            )
        }
        let reloaded = try #require(try fixture.store.load(documentID: created.documentID))
        #expect(reloaded.revision == 1)
        #expect(reloaded.content == "aaa")
    }

    @Test
    func oversizedPatchPayloadIsRejectedBeforeDecode() throws {
        let fixture = try ScratchpadDocumentStoreFixture(maxPatchBytes: 8)
        let created = try fixture.store.createDocument(
            title: nil,
            content: "first",
            sessionLink: nil
        )

        #expect(throws: ScratchpadDocumentStoreError.patchTooLarge(maxBytes: 8, actualBytes: 19)) {
            try fixture.store.applyPatch(
                documentID: created.documentID,
                patchJSON: #"{"replacements":[]}"#,
                expectedRevision: 1,
                sessionLink: nil
            )
        }
    }

    @Test
    func oversizedFinalContentIsRejectedAndLeavesDocumentUntouched() throws {
        let fixture = try ScratchpadDocumentStoreFixture(maxContentBytes: 10)
        let created = try fixture.store.createDocument(
            title: nil,
            content: "1234567890",
            sessionLink: nil
        )

        #expect(throws: ScratchpadDocumentStoreError.contentTooLarge(maxBytes: 10, actualBytes: 11)) {
            try fixture.store.applyPatch(
                documentID: created.documentID,
                patchJSON: try patchJSON([.init(oldText: "0", newText: "00")]),
                expectedRevision: 1,
                sessionLink: nil
            )
        }
        let reloaded = try #require(try fixture.store.load(documentID: created.documentID))
        #expect(reloaded.revision == 1)
        #expect(reloaded.content == "1234567890")
    }

    @Test
    func concurrentPatchesWithSameRevisionSerializeSoOneWins() throws {
        let fixture = try ScratchpadDocumentStoreFixture()
        let created = try fixture.store.createDocument(
            title: nil,
            content: "needle",
            sessionLink: nil
        )
        let collector = ConcurrentPatchCollector()

        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                let outcome = try fixture.store.applyPatch(
                    documentID: created.documentID,
                    patchJSON: try patchJSON([.init(oldText: "needle", newText: "patched-\(index)")]),
                    expectedRevision: 1,
                    sessionLink: nil
                )
                collector.appendSuccess(outcome.revision)
            } catch ScratchpadDocumentStoreError.staleRevision(expectedRevision: 1, currentRevision: 2) {
                collector.incrementStaleFailures()
            } catch {
                collector.appendUnexpected(String(describing: error))
            }
        }

        let reloaded = try #require(try fixture.store.load(documentID: created.documentID))
        #expect(collector.successfulRevisions == [2])
        #expect(collector.staleFailures == 15)
        #expect(collector.unexpectedErrors.isEmpty)
        #expect(reloaded.revision == 2)
        #expect(reloaded.content.hasPrefix("patched-"))
    }
}

private final class ConcurrentPatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var successfulRevisions: [Int] = []
    private(set) var staleFailures = 0
    private(set) var unexpectedErrors: [String] = []

    func appendSuccess(_ revision: Int) {
        lock.withLock { successfulRevisions.append(revision) }
    }

    func incrementStaleFailures() {
        lock.withLock { staleFailures += 1 }
    }

    func appendUnexpected(_ description: String) {
        lock.withLock { unexpectedErrors.append(description) }
    }
}

private struct ScratchpadDocumentStoreFixture {
    let directoryURL: URL
    let store: ScratchpadDocumentStore

    init(
        maxContentBytes: Int = ScratchpadDocumentStore.defaultMaxContentBytes,
        maxPatchBytes: Int = ScratchpadDocumentStore.defaultMaxPatchBytes
    ) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = ScratchpadDocumentStore(
            directoryURL: directoryURL,
            maxContentBytes: maxContentBytes,
            maxPatchBytes: maxPatchBytes
        )
    }
}

private func patchJSON(_ replacements: [ScratchpadContentReplacement]) throws -> String {
    let encoder = JSONEncoder()
    let data = try encoder.encode(ScratchpadContentPatch(replacements: replacements))
    return try #require(String(data: data, encoding: .utf8))
}
