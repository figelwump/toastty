import Foundation

public struct PaneHistoryPruneResult: Equatable, Sendable {
    public let removedFileCount: Int
    public let failedRemovalCount: Int

    public init(removedFileCount: Int, failedRemovalCount: Int) {
        self.removedFileCount = removedFileCount
        self.failedRemovalCount = failedRemovalCount
    }
}

public struct PaneHistoryStore: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public init(runtimePaths: ToasttyRuntimePaths) {
        self.init(directoryURL: runtimePaths.paneHistoryDirectoryURL)
    }

    public func pruneUnreferencedHistoryFiles(
        keepingPanelIDs livePanelIDs: Set<UUID>,
        fileManager: FileManager = .default
    ) -> PaneHistoryPruneResult {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return PaneHistoryPruneResult(removedFileCount: 0, failedRemovalCount: 0)
        }

        let historyFileURLs: [URL]
        do {
            historyFileURLs = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            ToasttyLog.warning(
                "Failed reading pane history directory for pruning",
                category: .state,
                metadata: [
                    "directory": directoryURL.path,
                    "error": error.localizedDescription,
                ]
            )
            return PaneHistoryPruneResult(removedFileCount: 0, failedRemovalCount: 0)
        }

        var removedFileCount = 0
        var failedRemovalCount = 0

        for historyFileURL in historyFileURLs {
            guard historyFileURL.pathExtension == "history" else { continue }
            let resourceValues = try? historyFileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile != false else { continue }

            let panelIDComponent = historyFileURL.deletingPathExtension().lastPathComponent
            guard let panelID = UUID(uuidString: panelIDComponent),
                  livePanelIDs.contains(panelID) == false else {
                continue
            }

            do {
                try fileManager.removeItem(at: historyFileURL)
                removedFileCount += 1
            } catch {
                failedRemovalCount += 1
                ToasttyLog.warning(
                    "Failed removing stale pane history file",
                    category: .state,
                    metadata: [
                        "path": historyFileURL.path,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }

        return PaneHistoryPruneResult(
            removedFileCount: removedFileCount,
            failedRemovalCount: failedRemovalCount
        )
    }
}
