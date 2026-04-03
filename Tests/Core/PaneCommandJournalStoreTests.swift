import CoreState
import Foundation
import Testing

struct PaneCommandJournalStoreTests {
    @Test
    func pruneUnreferencedJournalFilesRemovesOnlyStalePaneJournalFiles() throws {
        let directoryURL = try makeTemporaryJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }

        let livePanelID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let stalePanelID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let liveJournalURL = directoryURL.appendingPathComponent("\(livePanelID.uuidString).journal")
        let staleJournalURL = directoryURL.appendingPathComponent("\(stalePanelID.uuidString).journal")
        let ignoredTextFileURL = directoryURL.appendingPathComponent("notes.txt")
        let ignoredInvalidJournalURL = directoryURL.appendingPathComponent("not-a-panel.journal")
        let ignoredDirectoryURL = directoryURL.appendingPathComponent("nested.journal", isDirectory: true)

        try Data("live".utf8).write(to: liveJournalURL, options: .atomic)
        try Data("stale".utf8).write(to: staleJournalURL, options: .atomic)
        try Data("notes".utf8).write(to: ignoredTextFileURL, options: .atomic)
        try Data("invalid".utf8).write(to: ignoredInvalidJournalURL, options: .atomic)
        try FileManager.default.createDirectory(at: ignoredDirectoryURL, withIntermediateDirectories: true)

        let result = PaneCommandJournalStore(directoryURL: directoryURL)
            .pruneUnreferencedJournalFiles(keepingPanelIDs: [livePanelID])

        #expect(result.removedFileCount == 1)
        #expect(result.failedRemovalCount == 0)
        #expect(FileManager.default.fileExists(atPath: liveJournalURL.path))
        #expect(FileManager.default.fileExists(atPath: staleJournalURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: ignoredTextFileURL.path))
        #expect(FileManager.default.fileExists(atPath: ignoredInvalidJournalURL.path))
        #expect(FileManager.default.fileExists(atPath: ignoredDirectoryURL.path))
    }

    @Test
    func pruneUnreferencedJournalFilesIgnoresMissingDirectory() {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-pane-journal-tests-\(UUID().uuidString)", isDirectory: true)

        let result = PaneCommandJournalStore(directoryURL: directoryURL)
            .pruneUnreferencedJournalFiles(keepingPanelIDs: [])

        #expect(result.removedFileCount == 0)
        #expect(result.failedRemovalCount == 0)
    }

    private func makeTemporaryJournalDirectory() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-pane-journal-tests-\(UUID().uuidString)", isDirectory: true)
        let directoryURL = rootURL.appendingPathComponent("history/pane-journals", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
