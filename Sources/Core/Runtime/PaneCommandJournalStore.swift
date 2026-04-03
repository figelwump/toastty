import Foundation

public struct PaneCommandJournalPruneResult: Equatable, Sendable {
    public let removedFileCount: Int
    public let failedRemovalCount: Int

    public init(removedFileCount: Int, failedRemovalCount: Int) {
        self.removedFileCount = removedFileCount
        self.failedRemovalCount = failedRemovalCount
    }
}

public struct PaneCommandJournalStore: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public init(runtimePaths: ToasttyRuntimePaths) {
        self.init(directoryURL: runtimePaths.paneJournalDirectoryURL)
    }

    public func pruneUnreferencedJournalFiles(
        keepingPanelIDs livePanelIDs: Set<UUID>,
        fileManager: FileManager = .default
    ) -> PaneCommandJournalPruneResult {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return PaneCommandJournalPruneResult(removedFileCount: 0, failedRemovalCount: 0)
        }

        let journalFileURLs: [URL]
        do {
            journalFileURLs = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            ToasttyLog.warning(
                "Failed reading pane journal directory for pruning",
                category: .state,
                metadata: [
                    "directory": directoryURL.path,
                    "error": error.localizedDescription,
                ]
            )
            return PaneCommandJournalPruneResult(removedFileCount: 0, failedRemovalCount: 0)
        }

        var removedFileCount = 0
        var failedRemovalCount = 0

        for journalFileURL in journalFileURLs {
            guard journalFileURL.pathExtension == "journal" else { continue }
            let resourceValues = try? journalFileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile != false else { continue }

            let panelIDComponent = journalFileURL.deletingPathExtension().lastPathComponent
            guard let panelID = UUID(uuidString: panelIDComponent),
                  livePanelIDs.contains(panelID) == false else {
                continue
            }

            do {
                try fileManager.removeItem(at: journalFileURL)
                removedFileCount += 1
            } catch {
                failedRemovalCount += 1
                ToasttyLog.warning(
                    "Failed removing stale pane journal file",
                    category: .state,
                    metadata: [
                        "path": journalFileURL.path,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }

        return PaneCommandJournalPruneResult(
            removedFileCount: removedFileCount,
            failedRemovalCount: failedRemovalCount
        )
    }
}
