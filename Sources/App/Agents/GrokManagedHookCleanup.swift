import Foundation

/// Session-scoped Grok hook JSON files live under `$GROK_HOME/hooks/` as
/// `toastty-<sessionID>.json`. Cleanup must always delete these even when the
/// launch-artifact directory is retained after session stop.
enum GrokManagedHookCleanup {
    private static let hookFileNamePrefix = "toastty-"
    private static let hookFileNameSuffix = ".json"
    /// Top-level key Toastty writes into the discovery JSON (Grok only reads `hooks`).
    static let ownerMetadataKey = "toastty"
    /// Legacy / unowned files older than this may be swept on cold start.
    static let unownedStaleInterval: TimeInterval = 24 * 60 * 60

    struct HookOwnerMetadata: Equatable {
        var ownerPID: Int32
        var managedSessionID: String
        var createdAtUnix: TimeInterval
    }

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
    /// Prefer this when the caller knows the live managed-session set for this process.
    static func removeOrphanHookFiles(
        in hooksDirectory: URL,
        activeSessionIDs: Set<String>,
        fileManager: FileManager
    ) {
        sweepHookFiles(in: hooksDirectory, fileManager: fileManager) { sessionID, _, _ in
            activeSessionIDs.contains(sessionID) == false
        }
    }

    /// Cold-start sweep across `$GROK_HOME/hooks`.
    ///
    /// Does **not** treat every `toastty-*.json` as orphaned: another live Toastty
    /// instance may share the same `GROK_HOME`. Files that embed owner PID metadata
    /// are kept while that process is still alive. Unowned/legacy files are only
    /// removed when older than `unownedStaleInterval`.
    static func removeOrphanHookFilesAtColdStart(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        now: Date = Date(),
        isProcessAlive: (Int32) -> Bool = { pid in
            pid > 0 && kill(pid, 0) == 0
        }
    ) {
        let grokHome = resolveGrokHomeURL(environment: environment, fileManager: fileManager)
        sweepHookFiles(
            in: grokHome.appendingPathComponent("hooks", isDirectory: true),
            fileManager: fileManager
        ) { _, owner, resourceValues in
            if let owner {
                return isProcessAlive(owner.ownerPID) == false
            }
            // Legacy files without owner metadata: only age-based cleanup so a
            // concurrent Toastty launch is not racing cold-start deletion.
            let contentDate = resourceValues.contentModificationDate
                ?? resourceValues.creationDate
            guard let contentDate else {
                return false
            }
            return now.timeIntervalSince(contentDate) >= unownedStaleInterval
        }
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

    static func ownerMetadata(
        ownerPID: Int32,
        managedSessionID: String,
        createdAt: Date = Date()
    ) -> [String: Any] {
        [
            "ownerPID": Int(ownerPID),
            "managedSessionID": managedSessionID,
            "createdAtUnix": createdAt.timeIntervalSince1970,
        ]
    }

    static func parseOwnerMetadata(from object: [String: Any]) -> HookOwnerMetadata? {
        guard let toastty = object[ownerMetadataKey] as? [String: Any] else {
            return nil
        }
        let pidValue: Int32?
        if let intValue = toastty["ownerPID"] as? Int {
            pidValue = Int32(intValue)
        } else if let number = toastty["ownerPID"] as? NSNumber {
            pidValue = number.int32Value
        } else {
            pidValue = nil
        }
        guard let pidValue,
              let managedSessionID = toastty["managedSessionID"] as? String,
              managedSessionID.isEmpty == false else {
            return nil
        }
        let createdAtUnix: TimeInterval
        if let value = toastty["createdAtUnix"] as? Double {
            createdAtUnix = value
        } else if let number = toastty["createdAtUnix"] as? NSNumber {
            createdAtUnix = number.doubleValue
        } else {
            createdAtUnix = 0
        }
        return HookOwnerMetadata(
            ownerPID: pidValue,
            managedSessionID: managedSessionID,
            createdAtUnix: createdAtUnix
        )
    }

    private static func sweepHookFiles(
        in hooksDirectory: URL,
        fileManager: FileManager,
        shouldDelete: (_ sessionID: String, _ owner: HookOwnerMetadata?, _ resourceValues: URLResourceValues) -> Bool
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
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .contentModificationDateKey,
                    .creationDateKey,
                ],
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

            let resourceValues: URLResourceValues
            do {
                resourceValues = try fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .contentModificationDateKey,
                    .creationDateKey,
                ])
            } catch {
                continue
            }
            guard resourceValues.isRegularFile == true else {
                continue
            }

            let owner = readOwnerMetadata(from: fileURL)
            guard shouldDelete(sessionID, owner, resourceValues) else {
                continue
            }
            removeHookFile(at: fileURL, fileManager: fileManager)
        }
    }

    private static func readOwnerMetadata(from fileURL: URL) -> HookOwnerMetadata? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseOwnerMetadata(from: object)
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
