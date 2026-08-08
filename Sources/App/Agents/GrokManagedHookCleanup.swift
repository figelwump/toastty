import Foundation

/// Session-scoped Grok hook JSON files live under `$GROK_HOME/hooks/` as
/// `toastty-<sessionID>.json`. Cleanup must always delete these even when the
/// launch-artifact directory is retained after session stop.
enum GrokManagedHookCleanup {
    private static let hookFileNamePrefix = "toastty-"
    private static let hookFileNameSuffix = ".json"

    static func hookFileURL(grokHome: URL, sessionID: String) -> URL {
        grokHome
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent(
                "\(hookFileNamePrefix)\(sessionID)\(hookFileNameSuffix)",
                isDirectory: false
            )
    }

    static func removeHookFile(at url: URL, fileManager: FileManager) {
        try? fileManager.removeItem(at: url)
    }

    /// Removes `toastty-*.json` files whose session id is not in `activeSessionIDs`.
    /// No-ops when the hooks directory is missing. Never deletes non-matching names.
    static func removeOrphanHookFiles(
        in hooksDirectory: URL,
        activeSessionIDs: Set<String>,
        fileManager: FileManager
    ) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: hooksDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: hooksDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return
        }

        for fileURL in contents {
            let name = fileURL.lastPathComponent
            guard let sessionID = sessionID(fromHookFileName: name) else {
                continue
            }
            guard activeSessionIDs.contains(sessionID) == false else {
                continue
            }

            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile == true else {
                continue
            }

            removeHookFile(at: fileURL, fileManager: fileManager)
        }
    }

    /// Cold-start sweep: no managed sessions are live yet, so every leftover
    /// `toastty-*.json` under the process GROK_HOME (or `~/.grok`) is an orphan.
    static func removeOrphanHookFilesAtColdStart(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        let grokHome = resolveGrokHomeURL(environment: environment, fileManager: fileManager)
        removeOrphanHookFiles(
            in: grokHome.appendingPathComponent("hooks", isDirectory: true),
            activeSessionIDs: [],
            fileManager: fileManager
        )
    }

    static func resolveGrokHomeURL(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> URL {
        if let grokHomePath = environment["GROK_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           grokHomePath.isEmpty == false {
            return URL(
                fileURLWithPath: (grokHomePath as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }

    private static func sessionID(fromHookFileName name: String) -> String? {
        guard name.hasPrefix(hookFileNamePrefix),
              name.hasSuffix(hookFileNameSuffix) else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: hookFileNamePrefix.count)
        let end = name.index(name.endIndex, offsetBy: -hookFileNameSuffix.count)
        guard start < end else {
            return nil
        }
        return String(name[start..<end])
    }
}
