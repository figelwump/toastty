import CoreState
import Foundation

/// Startup-only garbage collector for Toastty's managed-agent skill
/// artifacts. The staging roots under `<runtimePaths.agentPluginsDirectoryURL>`
/// are append-only during normal operation (`user/<sourceDigest>/` snapshots
/// and `claude/<version>-<digest>/` staging grow without bound), and failed
/// Codex cache swaps can leave transient `.toastty-old-*` / `.toastty-staging-*`
/// siblings inside `$CODEX_HOME/plugins/cache/toastty{,-user}/`.
///
/// `sweep()` is safe to run once at app startup because restore policy is
/// current-on-restore (restored sessions re-provision to current bundles) and
/// managed agent processes die with the app, so at startup no live process
/// references an old snapshot. Correctness against a mid-startup restore
/// preparation does not depend on the sweep finishing first:
///
/// - Each section holds the same lock its provider uses (the user catalog's
///   preparation lock, the Claude manager's serial staging queue, the Codex
///   manager's operation locks), so deletion and preparation serialize.
/// - The retention policy keeps exactly the artifacts the providers can
///   resolve: the current bundled Claude dir, the newest-receipt user
///   snapshot, and the next structurally verified fallback each provider
///   would pick if the newest is unusable. Lock-free readers
///   (`ToasttyUserSkillCatalog.existingSnapshot()`) therefore can never have
///   their selection deleted out from under them, and the delivery phase
///   byte-verifies everything it consumes and fails open regardless.
///
/// Deletion failures are logged and never fatal; the sweeper never blocks
/// startup on an error. Outside the narrowly scoped Codex cache-litter pass,
/// nothing outside `agentPluginsDirectoryURL` is ever touched.
final class ToasttySkillArtifactSweeper: @unchecked Sendable {
    /// Transient artifacts (staging dirs, retired cache subtrees) younger
    /// than this may belong to a concurrent run in another process and are
    /// left alone. Mirrors the user catalog's staging age gate.
    static let transientArtifactMaxAge: TimeInterval =
        ToasttyUserSkillCatalog.stagingOrphanMaxAge

    private let agentPluginsDirectoryURL: URL
    private let userSkillCatalog: ToasttyUserSkillCatalog
    private let claudeSkillsBundleManager: ClaudeSkillsBundleManager
    private let sourcePluginURLProvider: @Sendable () -> URL?
    private let fileManager: FileManager

    init(
        runtimePaths: ToasttyRuntimePaths,
        userSkillCatalog: ToasttyUserSkillCatalog,
        claudeSkillsBundleManager: ClaudeSkillsBundleManager,
        sourcePluginURLProvider: @escaping @Sendable () -> URL? = {
            ToasttyAgentPluginBundle.bundledPluginURL()
        },
        fileManager: FileManager = .default
    ) {
        agentPluginsDirectoryURL = runtimePaths.agentPluginsDirectoryURL
        self.userSkillCatalog = userSkillCatalog
        self.claudeSkillsBundleManager = claudeSkillsBundleManager
        self.sourcePluginURLProvider = sourcePluginURLProvider
        self.fileManager = fileManager
    }

    func sweep() {
        userSkillCatalog.withPreparationLock {
            sweepUserSnapshots()
        }
        claudeSkillsBundleManager.withExclusiveStagingAccess {
            sweepClaudeStaging()
        }
        CodexSkillsManager.withExclusiveCacheAccess {
            sweepCodexCacheLitter()
        }
        // codex/homes/<key>/ receipts are deliberately left alone: they are
        // tiny and required for the fast-path verification of every future
        // managed Codex launch.
    }
}

private extension ToasttySkillArtifactSweeper {
    // MARK: - user/<sourceDigest>/ snapshots

    /// Keeps the snapshot the newest receipt points at plus one previous
    /// structurally verified snapshot (the exact fallback
    /// `existingSnapshot()` would select if the newest is unusable). All
    /// other digest directories, receipt-less directories, and aged
    /// `.staging-*` orphans are deleted. Runs under the catalog's
    /// preparation lock.
    func sweepUserSnapshots() {
        let rootURL = agentPluginsDirectoryURL.appendingPathComponent("user", isDirectory: true)
        guard let children = directoryContents(of: rootURL) else { return }

        var assessed: [(url: URL, receiptModified: Date, isIntact: Bool)] = []
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(".staging-") {
                removeIfAged(child, reason: "aged user snapshot staging orphan")
                continue
            }
            // Only Toastty's snapshot directories are retention candidates;
            // other hidden files (for example `.DS_Store`) are left alone.
            guard name.hasPrefix(".") == false, isDirectory(child) else { continue }
            if let assessment = userSkillCatalog.assessSnapshotDirectoryForSweep(child) {
                assessed.append((child, assessment.receiptModified, assessment.isStructurallyIntact))
            } else {
                remove(child, reason: "user snapshot without a valid receipt")
            }
        }

        let ordered = assessed.sorted { $0.receiptModified > $1.receiptModified }
        var keptPaths = Set<String>()
        if let newest = ordered.first {
            keptPaths.insert(newest.url.path)
        }
        // Skip over structurally broken previous candidates in favor of an
        // older verified one; the skipped candidates are deleted below.
        if let previousVerified = ordered.dropFirst().first(where: { $0.isIntact }) {
            keptPaths.insert(previousVerified.url.path)
        }
        for entry in ordered where keptPaths.contains(entry.url.path) == false {
            remove(entry.url, reason: "superseded user skill snapshot")
        }
    }

    // MARK: - claude/<version>-<digest>/ staging

    /// Keeps the content-addressed directory matching the current bundled
    /// plugin plus the one most-recently-modified other directory that still
    /// verifies as a Toastty plugin bundle; deletes the rest and aged
    /// `.staging-*` orphans. Runs on the Claude manager's serial staging
    /// queue.
    func sweepClaudeStaging() {
        let rootURL = agentPluginsDirectoryURL.appendingPathComponent("claude", isDirectory: true)
        guard let children = directoryContents(of: rootURL) else { return }
        guard let sourceURL = sourcePluginURLProvider(),
              let source = try? ToasttyAgentPluginBundle.read(
                  pluginRootURL: sourceURL,
                  fileManager: fileManager
              ) else {
            // Without a readable bundled plugin the "current" identity is
            // unknown; deleting anything would risk removing the directory
            // the next launch needs, so only staging orphans are cleaned.
            for child in children where child.lastPathComponent.hasPrefix(".staging-") {
                removeIfAged(child, reason: "aged Claude staging orphan")
            }
            ToasttyLog.warning(
                "Skill artifact sweep skipped Claude staging retention; bundled plugin unreadable",
                category: .automation
            )
            return
        }
        let currentDirectoryName = "\(source.version)-\(source.contentDigest)"

        var verifiedOthers: [(url: URL, modified: Date)] = []
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(".staging-") {
                removeIfAged(child, reason: "aged Claude staging orphan")
                continue
            }
            guard name.hasPrefix(".") == false, isDirectory(child) else { continue }
            if name == currentDirectoryName { continue }
            // "Verified" reuses the bundle reader's checks (manifest pair,
            // exact shipped skill set, digest) against the directory's
            // content-addressed name — the same naming
            // `ClaudeSkillsBundleManager.destinationPluginURL` produces.
            let pluginURL = child.appendingPathComponent("toastty", isDirectory: true)
            if let installed = try? ToasttyAgentPluginBundle.read(
                pluginRootURL: pluginURL,
                fileManager: fileManager
            ), name == "\(installed.version)-\(installed.contentDigest)" {
                verifiedOthers.append((child, modificationDate(of: child)))
            } else {
                remove(child, reason: "unverifiable Claude skills staging directory")
            }
        }
        let ordered = verifiedOthers.sorted { $0.modified > $1.modified }
        for entry in ordered.dropFirst() {
            remove(entry.url, reason: "superseded Claude skills staging directory")
        }
    }

    // MARK: - Codex cache litter

    /// Minimal receipt shape shared by the shipped and user Codex receipts;
    /// only the recorded cache path matters here.
    struct CachePathReceipt: Decodable {
        let cachePath: String
    }

    /// Removes aged `.toastty-old-*` / `.toastty-staging-*` swap litter from
    /// `plugins/cache/toastty/` and `plugins/cache/toastty-user/` in each
    /// CODEX_HOME recorded by a receipt under `codex/homes/<key>/`. Other
    /// marketplaces' cache directories and the active version directories are
    /// never touched (only the two Toastty marketplace directories are
    /// visited, and only litter-prefixed children are removed). Runs while
    /// holding the Codex manager's operation locks so it cannot race an
    /// in-flight cache swap; at startup this is additionally safe because no
    /// launch preparation has been handed out yet.
    func sweepCodexCacheLitter() {
        let homesRootURL = agentPluginsDirectoryURL
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("homes", isDirectory: true)
        guard let homeStateDirectories = directoryContents(of: homesRootURL) else { return }

        var codexHomePaths = Set<String>()
        for homeStateDirectory in homeStateDirectories {
            for receiptName in ["receipt.json", "user-receipt.json"] {
                let receiptURL = homeStateDirectory.appendingPathComponent(receiptName, isDirectory: false)
                guard let data = try? Data(contentsOf: receiptURL),
                      let receipt = try? JSONDecoder().decode(CachePathReceipt.self, from: data),
                      let codexHomePath = codexHomePath(fromRecordedCachePath: receipt.cachePath) else {
                    continue
                }
                codexHomePaths.insert(codexHomePath)
            }
        }

        for codexHomePath in codexHomePaths {
            for marketplaceName in [
                CodexSkillsContract.marketplaceName,
                CodexUserSkillsContract.marketplaceName,
            ] {
                let marketplaceCacheURL = URL(fileURLWithPath: codexHomePath, isDirectory: true)
                    .appendingPathComponent("plugins/cache", isDirectory: true)
                    .appendingPathComponent(marketplaceName, isDirectory: true)
                guard let children = directoryContents(of: marketplaceCacheURL) else { continue }
                for child in children {
                    let name = child.lastPathComponent
                    guard name.hasPrefix(".toastty-old-")
                        || name.hasPrefix(".toastty-staging-") else {
                        continue
                    }
                    removeIfAged(child, reason: "aged Codex cache swap litter")
                }
            }
        }
    }

    /// Recorded cache paths have the shape
    /// `<codexHome>/plugins/cache/<marketplace>/<plugin>/<version>` with the
    /// marketplace and plugin both named `toastty` or both `toastty-user`.
    /// Anything else is rejected so a malformed receipt can never point the
    /// sweep at an arbitrary directory.
    func codexHomePath(fromRecordedCachePath path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let versionURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let components = versionURL.pathComponents
        guard components.count >= 7 else { return nil }
        let marketplaceName = components[components.count - 3]
        let pluginName = components[components.count - 2]
        guard components[components.count - 5] == "plugins",
              components[components.count - 4] == "cache",
              marketplaceName == pluginName,
              [CodexSkillsContract.marketplaceName, CodexUserSkillsContract.marketplaceName]
                  .contains(marketplaceName) else {
            return nil
        }
        var homeURL = versionURL
        for _ in 0..<5 {
            homeURL.deleteLastPathComponent()
        }
        return homeURL.path
    }

    // MARK: - Filesystem helpers

    /// Includes hidden entries (staging and litter names start with a dot).
    /// A missing or unreadable directory is a no-op — the sweeper never
    /// creates directories.
    func directoryContents(of url: URL) -> [URL]? {
        try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    func modificationDate(of url: URL) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            ?? .distantPast
    }

    func removeIfAged(_ url: URL, reason: String) {
        guard Date().timeIntervalSince(modificationDate(of: url))
            > Self.transientArtifactMaxAge else {
            return
        }
        remove(url, reason: reason)
    }

    func remove(_ url: URL, reason: String) {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            ToasttyLog.warning(
                "Skill artifact sweep could not delete an item",
                category: .automation,
                metadata: [
                    "path": url.path,
                    "reason": reason,
                    "error": error.localizedDescription,
                ]
            )
        }
    }
}
