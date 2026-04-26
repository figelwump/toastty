@testable import ToasttyApp
import CoreState
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
}

private struct ScratchpadDocumentStoreFixture {
    let directoryURL: URL
    let store: ScratchpadDocumentStore

    init(maxContentBytes: Int = 1_048_576) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = ScratchpadDocumentStore(
            directoryURL: directoryURL,
            maxContentBytes: maxContentBytes
        )
    }
}
