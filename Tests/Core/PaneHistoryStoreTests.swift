import CoreState
import Foundation
import Testing

struct PaneHistoryStoreTests {
    @Test
    func pruneUnreferencedHistoryFilesRemovesOnlyStalePaneHistoryFiles() throws {
        let directoryURL = try makeTemporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }

        let livePanelID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let stalePanelID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let liveHistoryURL = directoryURL.appendingPathComponent("\(livePanelID.uuidString).history")
        let staleHistoryURL = directoryURL.appendingPathComponent("\(stalePanelID.uuidString).history")
        let ignoredTextFileURL = directoryURL.appendingPathComponent("notes.txt")
        let ignoredInvalidHistoryURL = directoryURL.appendingPathComponent("not-a-panel.history")
        let ignoredDirectoryURL = directoryURL.appendingPathComponent("nested.history", isDirectory: true)

        try Data("live".utf8).write(to: liveHistoryURL, options: .atomic)
        try Data("stale".utf8).write(to: staleHistoryURL, options: .atomic)
        try Data("notes".utf8).write(to: ignoredTextFileURL, options: .atomic)
        try Data("invalid".utf8).write(to: ignoredInvalidHistoryURL, options: .atomic)
        try FileManager.default.createDirectory(at: ignoredDirectoryURL, withIntermediateDirectories: true)

        let result = PaneHistoryStore(directoryURL: directoryURL)
            .pruneUnreferencedHistoryFiles(keepingPanelIDs: [livePanelID])

        #expect(result.removedFileCount == 1)
        #expect(result.failedRemovalCount == 0)
        #expect(FileManager.default.fileExists(atPath: liveHistoryURL.path))
        #expect(FileManager.default.fileExists(atPath: staleHistoryURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: ignoredTextFileURL.path))
        #expect(FileManager.default.fileExists(atPath: ignoredInvalidHistoryURL.path))
        #expect(FileManager.default.fileExists(atPath: ignoredDirectoryURL.path))
    }

    @Test
    func pruneUnreferencedHistoryFilesIgnoresMissingDirectory() {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-pane-history-tests-\(UUID().uuidString)", isDirectory: true)

        let result = PaneHistoryStore(directoryURL: directoryURL)
            .pruneUnreferencedHistoryFiles(keepingPanelIDs: [])

        #expect(result.removedFileCount == 0)
        #expect(result.failedRemovalCount == 0)
    }

    private func makeTemporaryHistoryDirectory() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-pane-history-tests-\(UUID().uuidString)", isDirectory: true)
        let directoryURL = rootURL.appendingPathComponent("history/panes", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
