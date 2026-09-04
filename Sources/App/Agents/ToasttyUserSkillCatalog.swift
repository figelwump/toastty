import CoreState
import CryptoKit
import Darwin
import Foundation

/// An immutable, content-addressed `toastty-user` plugin snapshot built from
/// the accepted user skill packages, laid out as a throwaway-install
/// marketplace fixture ready for delivery to managed agent sessions.
struct UserSkillPluginSnapshot: Equatable, Sendable {
    static let pluginName = "toastty-user"

    let pluginName: String
    let version: String
    /// Digest of the accepted source payload (paths, bytes, executable bits).
    let sourceDigest: String
    /// `ToasttyAgentPluginBundle.contentDigest` over the generated plugin
    /// root, recorded for later cache verification by the delivery phase.
    let pluginContentDigest: String
    let pluginRootURL: URL
    /// The marketplace fixture root used for throwaway `codex plugin` installs.
    let marketplaceRootURL: URL
    let skillsRootURL: URL
    let receiptURL: URL
    let acceptedPackageNames: [String]
}

enum ToasttyUserSkillCatalogError: LocalizedError, Equatable {
    case sourceUnreadable(String)
    case snapshotWriteFailed(String)
    case snapshotVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnreadable(let path):
            return "Toastty could not read the user skill source at \(path)."
        case .snapshotWriteFailed(let path):
            return "Toastty could not write the user skills snapshot at \(path)."
        case .snapshotVerificationFailed(let path):
            return "Toastty could not verify the user skills snapshot at \(path)."
        }
    }
}

/// Launch-scoped resolution of the user skills plugin, distinguishing
/// provenance so delivery can tell "the user has no skills" apart from "the
/// resolution could not complete":
///
/// - `.empty` is asserted only when a completed source scan confirmed zero
///   accepted packages (or the converged absence of any snapshot). It is the
///   destructive-convergence trigger: delivered user state is removed.
/// - `.unavailable` covers timeouts, build errors, and unverifiable on-disk
///   state; it must never delete or rewrite previously delivered user state.
/// - `.snapshot` carries a verified snapshot to deliver.
enum UserSkillSnapshotResolution: Equatable, Sendable {
    case empty
    case unavailable
    case snapshot(UserSkillPluginSnapshot)

    var snapshot: UserSkillPluginSnapshot? {
        if case .snapshot(let snapshot) = self { return snapshot }
        return nil
    }
}

/// Launch-preparation seam over the catalog: the planner resolves one
/// snapshot per launch preparation and passes the same value to both hosts.
/// `prepareSnapshot()` may build; `existingSnapshot()` /
/// `existingSnapshotResolution()` are the cheap no-build reuse used by
/// synchronous and restored preparation.
protocol ToasttyUserSkillSnapshotProviding: AnyObject, Sendable {
    func prepareSnapshot() throws -> UserSkillPluginSnapshot?
    func existingSnapshot() -> UserSkillPluginSnapshot?
    func existingSnapshotResolution() -> UserSkillSnapshotResolution
}

extension ToasttyUserSkillSnapshotProviding {
    /// Default for test doubles without snapshot storage: a snapshot resolves
    /// as such; absence is treated as `.unavailable` (never destructive).
    /// `ToasttyUserSkillCatalog` overrides this with a disk-aware version
    /// that can confirm `.empty`.
    func existingSnapshotResolution() -> UserSkillSnapshotResolution {
        existingSnapshot().map { .snapshot($0) } ?? .unavailable
    }
}

/// Standalone catalog for user-created skill packages under the runtime
/// paths' `skills` directory. `scan()` is read-only; `prepareSnapshot()`
/// builds (or reuses) an immutable content-addressed `toastty-user` plugin
/// snapshot under `<agent-plugins>/user/<sourceDigest>/`. Delivery wiring is
/// a separate concern; this type never touches launch paths and never reads
/// `~/.codex`, `~/.claude`, or `~/.agents`.
final class ToasttyUserSkillCatalog: ToasttyUserSkillSnapshotProviding, @unchecked Sendable {
    /// The user's skill-package source directory, exposed for the management
    /// UI (empty-state path text and folder reveal/create actions).
    let userSkillsDirectoryURL: URL
    private let snapshotsRootURL: URL
    private let fileManager: FileManager
    /// Serializes snapshot preparation within this (app-scoped) instance so
    /// concurrent launch preparations cannot delete each other's staging or
    /// race the corrupt-snapshot rebuild.
    private let preparationLock = NSLock()
    private let digestMemoLock = NSLock()
    /// Per-process verdicts of the once-per-snapshot content digest
    /// verification performed by `existingSnapshot()`.
    private var digestVerificationMemo: [String: Bool] = [:]

    init(
        runtimePaths: ToasttyRuntimePaths = .resolve(),
        fileManager: FileManager = .default
    ) {
        userSkillsDirectoryURL = runtimePaths.userSkillsDirectoryURL
        snapshotsRootURL = runtimePaths.agentPluginsDirectoryURL
            .appendingPathComponent("user", isDirectory: true)
        self.fileManager = fileManager
    }

    /// Read-only validation pass over the user skills directory. Performs no
    /// writes. A missing directory yields an empty catalog.
    func scan() -> UserSkillCatalogState {
        validator.scan(userSkillsDirectoryURL: userSkillsDirectoryURL).state
    }

    /// Builds or reuses the immutable snapshot for the currently accepted
    /// packages. Returns nil only when a completed scan confirmed zero
    /// accepted packages — the confirmed-empty resolution — in which case any
    /// previously built snapshots are removed so `existingSnapshot()` and the
    /// sweeper stop treating removed skills as deliverable. An unreadable
    /// source directory throws instead: unconfirmed emptiness must never
    /// converge deliveries.
    func prepareSnapshot() throws -> UserSkillPluginSnapshot? {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        cleanupOrphanedStaging()
        let scanResult = validator.scan(userSkillsDirectoryURL: userSkillsDirectoryURL)
        let payloads = scanResult.acceptedPayloads
        guard payloads.isEmpty == false else {
            try confirmSourceEmptinessIsTrustworthy()
            removeAllSnapshotDirectories()
            return nil
        }

        let sourceDigest = try Self.sourceDigest(payloads: payloads, fileManager: fileManager)
        let version = Self.version(sourceDigest: sourceDigest)
        let destinationURL = snapshotsRootURL.appendingPathComponent(sourceDigest, isDirectory: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            if let existing = try? verifiedSnapshot(at: destinationURL, sourceDigest: sourceDigest) {
                // Refresh the receipt mtime so `existingSnapshot()`'s
                // newest-receipt selection matches the most recently prepared
                // snapshot (a content revert A→B→A would otherwise keep B
                // newest while launches deliver A).
                try? fileManager.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: existing.receiptURL.path
                )
                return existing
            }
            // A corrupt existing snapshot directory is removed and rebuilt.
            try fileManager.removeItem(at: destinationURL)
        }

        let stagingURL = snapshotsRootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try buildSnapshot(
                into: stagingURL,
                payloads: payloads,
                sourceDigest: sourceDigest,
                version: version
            )
            do {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            } catch where fileManager.fileExists(atPath: destinationURL.path) {
                // Another instance produced the same content-addressed
                // snapshot concurrently; verification below arbitrates.
                try? fileManager.removeItem(at: stagingURL)
            }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
        return try verifiedSnapshot(at: destinationURL, sourceDigest: sourceDigest)
    }

    /// Reuse of the newest already-built snapshot without scanning sources or
    /// staging anything. Every call performs structural existence checks
    /// (receipt decode, all plugin manifests, the skills root, and each
    /// accepted package directory). The receipt's recorded content digest is
    /// additionally recomputed once per process per snapshot identity and the
    /// verdict memoized, so half-deleted or tampered snapshots are rejected
    /// before their root can reach a `--plugin-dir` argument, while repeat
    /// synchronous launches stay cheap. Content changes after a verified
    /// first read are out of scope here — the snapshot is Toastty-owned and
    /// content-addressed, and the Codex side always byte-verifies its own
    /// delivered cache.
    func existingSnapshot() -> UserSkillPluginSnapshot? {
        guard let children = try? fileManager.contentsOfDirectory(
            at: snapshotsRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var newest: (modified: Date, snapshot: UserSkillPluginSnapshot)?
        for child in children {
            let receiptURL = child.appendingPathComponent(Self.receiptFileName)
            guard let data = try? Data(contentsOf: receiptURL),
                  let receipt = try? JSONDecoder().decode(SnapshotReceipt.self, from: data),
                  receipt.schemaVersion == 1,
                  receipt.pluginName == UserSkillPluginSnapshot.pluginName,
                  receipt.sourceDigest == child.lastPathComponent,
                  receipt.version == Self.version(sourceDigest: receipt.sourceDigest) else {
                continue
            }
            let marketplaceRootURL = child.appendingPathComponent(
                Self.marketplaceDirectoryName,
                isDirectory: true
            )
            let pluginRootURL = marketplaceRootURL
                .appendingPathComponent("plugins", isDirectory: true)
                .appendingPathComponent(UserSkillPluginSnapshot.pluginName, isDirectory: true)
            guard hasIntactStructure(pluginRootURL: pluginRootURL, receipt: receipt),
                  hasVerifiedContentDigest(pluginRootURL: pluginRootURL, receipt: receipt) else {
                continue
            }
            let modified = (try? fileManager.attributesOfItem(atPath: receiptURL.path))?[.modificationDate] as? Date
                ?? .distantPast
            guard newest == nil || modified > newest!.modified else { continue }
            newest = (modified, UserSkillPluginSnapshot(
                pluginName: receipt.pluginName,
                version: receipt.version,
                sourceDigest: receipt.sourceDigest,
                pluginContentDigest: receipt.pluginContentDigest,
                pluginRootURL: pluginRootURL,
                marketplaceRootURL: marketplaceRootURL,
                skillsRootURL: pluginRootURL.appendingPathComponent("skills", isDirectory: true),
                receiptURL: receiptURL,
                acceptedPackageNames: receipt.acceptedPackageNames
            ))
        }
        return newest?.snapshot
    }

    /// Disk-aware resolution for synchronous and restored launch preparation:
    /// a verified snapshot resolves as such; an entirely absent snapshot
    /// store (converged empty or never prepared) is confirmed `.empty`; a
    /// store that exists but cannot be enumerated (permissions, I/O), or
    /// whose snapshot directories all fail verification, is `.unavailable`
    /// so delivery never destroys state it could not read.
    func existingSnapshotResolution() -> UserSkillSnapshotResolution {
        if let snapshot = existingSnapshot() {
            return .snapshot(snapshot)
        }
        guard fileManager.fileExists(atPath: snapshotsRootURL.path) else {
            // A missing snapshot root has nothing to deliver anywhere.
            return .empty
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: snapshotsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            // Present but unreadable: unconfirmed emptiness must never be a
            // destructive signal.
            return .unavailable
        }
        let hasSnapshotDirectories = children.contains { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        return hasSnapshotDirectories ? .unavailable : .empty
    }

    /// Rescan seam for the management UI: rebuilds (or reuses) the snapshot
    /// from the current user skill sources.
    @discardableResult
    func refreshUserSkills() throws -> UserSkillPluginSnapshot? {
        try prepareSnapshot()
    }

    // MARK: - Sweep seams

    /// Staging directories younger than this are presumed to belong to a
    /// concurrent build (defense against multi-process runs; in-process runs
    /// are serialized by `preparationLock`). Internal so
    /// `ToasttySkillArtifactSweeper` shares the same age gate.
    static let stagingOrphanMaxAge: TimeInterval = 3600

    /// Serializes `body` against snapshot preparation. Used by
    /// `ToasttySkillArtifactSweeper` so startup GC cannot race a concurrent
    /// `prepareSnapshot()` build or the corrupt-snapshot rebuild.
    func withPreparationLock<T>(_ body: () throws -> T) rethrows -> T {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        return try body()
    }

    /// Sweep seam for `ToasttySkillArtifactSweeper`: decodes the snapshot
    /// receipt at `directoryURL` with the same checks `existingSnapshot()`
    /// applies and reports its modification date plus whether the snapshot
    /// passes the structural integrity checks. Content digests are
    /// deliberately not recomputed — sweep retention is structural, and the
    /// delivery phase byte-verifies whatever it consumes. Returns nil when
    /// the directory carries no valid receipt.
    func assessSnapshotDirectoryForSweep(
        _ directoryURL: URL
    ) -> (receiptModified: Date, isStructurallyIntact: Bool)? {
        let receiptURL = directoryURL.appendingPathComponent(Self.receiptFileName)
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(SnapshotReceipt.self, from: data),
              receipt.schemaVersion == 1,
              receipt.pluginName == UserSkillPluginSnapshot.pluginName,
              receipt.sourceDigest == directoryURL.lastPathComponent,
              receipt.version == Self.version(sourceDigest: receipt.sourceDigest) else {
            return nil
        }
        let pluginRootURL = directoryURL
            .appendingPathComponent(Self.marketplaceDirectoryName, isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(UserSkillPluginSnapshot.pluginName, isDirectory: true)
        let modified = (try? fileManager.attributesOfItem(atPath: receiptURL.path))?[.modificationDate] as? Date
            ?? .distantPast
        return (modified, hasIntactStructure(pluginRootURL: pluginRootURL, receipt: receipt))
    }
}

private extension ToasttyUserSkillCatalog {
    static let versionForm = "semver-prerelease"
    static let receiptFileName = "receipt.json"
    static let marketplaceDirectoryName = "marketplace"
    static let pluginDescription = "User-created Toastty skills."
    static let authorName = "Giant Things"
    static let displayName = "Toastty User Skills"

    struct SnapshotReceipt: Codable, Equatable {
        let schemaVersion: Int
        let pluginName: String
        let version: String
        /// "semver-prerelease" (`0.1.0-<hex12>`); a purely numeric fallback
        /// form exists in case a future Codex rejects prerelease versions.
        let versionForm: String
        let sourceDigest: String
        let pluginContentDigest: String
        let acceptedPackageNames: [String]
    }

    var validator: ToasttyUserSkillValidator {
        ToasttyUserSkillValidator(fileManager: fileManager)
    }

    /// Semver prerelease form, verified accepted by the Codex CLI (see the
    /// live acceptance test in ToasttyUserSkillCatalogTests).
    static func version(sourceDigest: String) -> String {
        "0.1.0-\(sourceDigest.prefix(12))"
    }

    // MARK: - Source digest

    /// Digest over the accepted source payload: sorted relative paths, file
    /// bytes, and executable bits, length-prefixed into SHA-256. Mirrors the
    /// framing of `ToasttyAgentPluginBundle.contentDigest` but additionally
    /// covers the executable bit (user packages may rely on helper scripts),
    /// so it is a deliberate parallel implementation rather than a shared
    /// helper.
    ///
    /// Deliberate asymmetry with `ToasttyAgentPluginBundle.contentDigest`:
    /// SOURCE identity must detect exec-bit changes (they change delivered
    /// behavior — the bit is mirrored onto staged copies), so the bit is
    /// hashed here; PLUGIN-CONTENT identity excludes modes because staged and
    /// cached copies get their permissions normalized deterministically after
    /// every copy. Do NOT change either algorithm — changing the content
    /// digest would invalidate every existing receipt and cache.
    static func sourceDigest(
        payloads: [ToasttyUserSkillScanResult.PackagePayload],
        fileManager: FileManager
    ) throws -> String {
        var hasher = SHA256()
        for payload in payloads.sorted(by: { $0.name < $1.name }) {
            for file in payload.files.sorted(by: { $0.relativePath < $1.relativePath }) {
                let relativePath = "\(payload.name)/\(file.relativePath)"
                let data = try readRegularFileNoFollow(at: file.sourceURL)
                let executableBit = file.isExecutable ? "x" : "-"
                hasher.update(data: Data(
                    "file:\(relativePath.utf8.count):\(relativePath):\(executableBit):\(data.count):".utf8
                ))
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// O_NOFOLLOW read so a symlink swapped in after validation can never leak
    /// out-of-package bytes into a snapshot. O_NONBLOCK guards the open itself:
    /// a FIFO swapped in after validation would otherwise block `open()`
    /// forever (a reader waits for a writer). The flag is cleared before
    /// reading — it never affects reads of the regular files we accept.
    static func readRegularFileNoFollow(at url: URL) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw ToasttyUserSkillCatalogError.sourceUnreadable(url.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw ToasttyUserSkillCatalogError.sourceUnreadable(url.path)
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
            throw ToasttyUserSkillCatalogError.sourceUnreadable(url.path)
        }
        guard let data = try? handle.readToEnd() else {
            throw ToasttyUserSkillCatalogError.sourceUnreadable(url.path)
        }
        return data
    }

    // MARK: - Snapshot building

    func buildSnapshot(
        into stagingURL: URL,
        payloads: [ToasttyUserSkillScanResult.PackagePayload],
        sourceDigest: String,
        version: String
    ) throws {
        let marketplaceRootURL = stagingURL.appendingPathComponent(
            Self.marketplaceDirectoryName,
            isDirectory: true
        )
        let pluginRootURL = marketplaceRootURL
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(UserSkillPluginSnapshot.pluginName, isDirectory: true)
        let skillsRootURL = pluginRootURL.appendingPathComponent("skills", isDirectory: true)

        do {
            try fileManager.createDirectory(at: skillsRootURL, withIntermediateDirectories: true)
            for payload in payloads {
                let packageURL = skillsRootURL.appendingPathComponent(payload.name, isDirectory: true)
                try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
                for file in payload.files {
                    let destinationURL = packageURL.appendingPathComponent(file.relativePath)
                    try fileManager.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let data = try Self.readRegularFileNoFollow(at: file.sourceURL)
                    try data.write(to: destinationURL)
                    // Normalize modes: executables stay executable, everything
                    // else becomes a plain readable file.
                    try fileManager.setAttributes(
                        [.posixPermissions: file.isExecutable ? 0o755 : 0o644],
                        ofItemAtPath: destinationURL.path
                    )
                    removeQuarantineAttribute(at: destinationURL)
                }
            }
            try writeManifests(
                marketplaceRootURL: marketplaceRootURL,
                pluginRootURL: pluginRootURL,
                version: version
            )
        } catch let error as ToasttyUserSkillCatalogError {
            throw error
        } catch {
            throw ToasttyUserSkillCatalogError.snapshotWriteFailed(stagingURL.path)
        }

        let pluginContentDigest: String
        do {
            pluginContentDigest = try ToasttyAgentPluginBundle.contentDigest(
                rootURL: pluginRootURL,
                fileManager: fileManager
            )
        } catch {
            throw ToasttyUserSkillCatalogError.snapshotWriteFailed(pluginRootURL.path)
        }

        // The receipt is written last: a snapshot directory without a receipt
        // is incomplete by construction and is cleaned up as staging debris.
        let receipt = SnapshotReceipt(
            schemaVersion: 1,
            pluginName: UserSkillPluginSnapshot.pluginName,
            version: version,
            versionForm: Self.versionForm,
            sourceDigest: sourceDigest,
            pluginContentDigest: pluginContentDigest,
            acceptedPackageNames: payloads.map(\.name)
        )
        do {
            try encodeJSON(receipt)
                .write(to: stagingURL.appendingPathComponent(Self.receiptFileName))
        } catch {
            throw ToasttyUserSkillCatalogError.snapshotWriteFailed(stagingURL.path)
        }
    }

    func writeManifests(
        marketplaceRootURL: URL,
        pluginRootURL: URL,
        version: String
    ) throws {
        let interface = InterfacePayload(
            displayName: Self.displayName,
            shortDescription: Self.pluginDescription,
            longDescription: Self.pluginDescription,
            developerName: Self.authorName,
            category: "Developer Tools",
            capabilities: ["Interactive"],
            defaultPrompt: ["Use a user-created Toastty skill."]
        )
        let codexManifest = CodexManifestPayload(
            name: UserSkillPluginSnapshot.pluginName,
            version: version,
            description: Self.pluginDescription,
            author: AuthorPayload(name: Self.authorName),
            skills: "./skills/",
            interface: interface
        )
        let claudeManifest = ClaudeManifestPayload(
            name: UserSkillPluginSnapshot.pluginName,
            version: version,
            description: Self.pluginDescription,
            author: AuthorPayload(name: Self.authorName)
        )
        let cursorManifest = CursorManifestPayload(
            name: UserSkillPluginSnapshot.pluginName,
            version: version,
            description: Self.pluginDescription,
            author: AuthorPayload(name: Self.authorName),
            skills: "./skills/"
        )
        let marketplace = MarketplacePayload(
            name: UserSkillPluginSnapshot.pluginName,
            interface: MarketplaceInterfacePayload(displayName: Self.displayName),
            plugins: [MarketplacePluginEntryPayload(
                name: UserSkillPluginSnapshot.pluginName,
                source: MarketplaceSourcePayload(
                    source: "local",
                    path: "./plugins/\(UserSkillPluginSnapshot.pluginName)"
                ),
                policy: MarketplacePolicyPayload(
                    installation: "AVAILABLE",
                    authentication: "ON_INSTALL"
                ),
                category: "Developer Tools"
            )]
        )

        let codexManifestURL = pluginRootURL
            .appendingPathComponent(".codex-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json")
        let claudeManifestURL = pluginRootURL
            .appendingPathComponent(".claude-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json")
        let cursorManifestURL = pluginRootURL
            .appendingPathComponent(".cursor-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json")
        let marketplaceManifestURL = marketplaceRootURL
            .appendingPathComponent(".agents/plugins", isDirectory: true)
            .appendingPathComponent("marketplace.json")
        for (url, data) in [
            (codexManifestURL, try encodeJSON(codexManifest)),
            (claudeManifestURL, try encodeJSON(claudeManifest)),
            (cursorManifestURL, try encodeJSON(cursorManifest)),
            (marketplaceManifestURL, try encodeJSON(marketplace)),
        ] {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
    }

    func encodeJSON(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(Data("\n".utf8))
        return data
    }

    // MARK: - Verification and reuse

    func verifiedSnapshot(
        at snapshotURL: URL,
        sourceDigest: String
    ) throws -> UserSkillPluginSnapshot {
        let receiptURL = snapshotURL.appendingPathComponent(Self.receiptFileName)
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(SnapshotReceipt.self, from: data),
              receipt.schemaVersion == 1,
              receipt.pluginName == UserSkillPluginSnapshot.pluginName,
              receipt.sourceDigest == sourceDigest,
              receipt.version == Self.version(sourceDigest: sourceDigest) else {
            throw ToasttyUserSkillCatalogError.snapshotVerificationFailed(snapshotURL.path)
        }
        let marketplaceRootURL = snapshotURL.appendingPathComponent(
            Self.marketplaceDirectoryName,
            isDirectory: true
        )
        let pluginRootURL = marketplaceRootURL
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(UserSkillPluginSnapshot.pluginName, isDirectory: true)
        guard let pluginContentDigest = try? ToasttyAgentPluginBundle.contentDigest(
            rootURL: pluginRootURL,
            fileManager: fileManager
        ), pluginContentDigest == receipt.pluginContentDigest else {
            throw ToasttyUserSkillCatalogError.snapshotVerificationFailed(snapshotURL.path)
        }
        return UserSkillPluginSnapshot(
            pluginName: receipt.pluginName,
            version: receipt.version,
            sourceDigest: receipt.sourceDigest,
            pluginContentDigest: receipt.pluginContentDigest,
            pluginRootURL: pluginRootURL,
            marketplaceRootURL: marketplaceRootURL,
            skillsRootURL: pluginRootURL.appendingPathComponent("skills", isDirectory: true),
            receiptURL: receiptURL,
            acceptedPackageNames: receipt.acceptedPackageNames
        )
    }

    // MARK: - Confirmed-empty convergence

    /// An empty accepted set is trusted as "the user has no skills" only when
    /// the source directory is genuinely absent or listable. A directory that
    /// exists but cannot be listed (or a non-directory occupying the path)
    /// throws so the caller resolves `.unavailable` instead of converging.
    func confirmSourceEmptinessIsTrustworthy() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: userSkillsDirectoryURL.path,
            isDirectory: &isDirectory
        ) else {
            return
        }
        guard isDirectory.boolValue,
              (try? fileManager.contentsOfDirectory(atPath: userSkillsDirectoryURL.path)) != nil else {
            throw ToasttyUserSkillCatalogError.sourceUnreadable(userSkillsDirectoryURL.path)
        }
    }

    /// Confirmed-empty convergence: with zero accepted packages, previously
    /// built snapshots must stop being deliverable everywhere —
    /// `existingSnapshot()` selection, restored Codex verification, and the
    /// sweeper's retention all assume on-disk snapshots are deliverable. Runs
    /// under `preparationLock`; fresh `.staging-*` directories (a concurrent
    /// multi-process build) are left alone.
    func removeAllSnapshotDirectories() {
        guard let children = try? fileManager.contentsOfDirectory(
            at: snapshotsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for child in children where
            (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            try? fileManager.removeItem(at: child)
        }
    }

    // MARK: - Existing-snapshot verification

    /// Structural existence checks run on every `existingSnapshot()` call:
    /// all plugin manifests, the skills root, and each accepted package
    /// directory named in the receipt.
    func hasIntactStructure(pluginRootURL: URL, receipt: SnapshotReceipt) -> Bool {
        let skillsRootURL = pluginRootURL.appendingPathComponent("skills", isDirectory: true)
        var requiredPaths = [
            pluginRootURL.appendingPathComponent(".codex-plugin/plugin.json").path,
            pluginRootURL.appendingPathComponent(".claude-plugin/plugin.json").path,
            pluginRootURL.appendingPathComponent(".cursor-plugin/plugin.json").path,
            skillsRootURL.path,
        ]
        requiredPaths += receipt.acceptedPackageNames.map { name in
            skillsRootURL.appendingPathComponent(name, isDirectory: true).path
        }
        return requiredPaths.allSatisfy { fileManager.fileExists(atPath: $0) }
    }

    /// Recomputes the plugin content digest once per process per snapshot
    /// identity and memoizes the verdict; repeat calls trust the memo.
    func hasVerifiedContentDigest(pluginRootURL: URL, receipt: SnapshotReceipt) -> Bool {
        let memoKey = "\(receipt.sourceDigest)|\(receipt.pluginContentDigest)"
        digestMemoLock.lock()
        let memo = digestVerificationMemo[memoKey]
        digestMemoLock.unlock()
        if let memo { return memo }
        let digest = try? ToasttyAgentPluginBundle.contentDigest(
            rootURL: pluginRootURL,
            fileManager: fileManager
        )
        let verified = digest == receipt.pluginContentDigest
        digestMemoLock.lock()
        digestVerificationMemo[memoKey] = verified
        digestMemoLock.unlock()
        return verified
    }

    // MARK: - Housekeeping

    func cleanupOrphanedStaging() {
        guard let children = try? fileManager.contentsOfDirectory(
            at: snapshotsRootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }
        for child in children where child.lastPathComponent.hasPrefix(".staging-") {
            let modified = (try? fileManager.attributesOfItem(atPath: child.path))?[.modificationDate] as? Date
                ?? .distantPast
            guard Date().timeIntervalSince(modified) > Self.stagingOrphanMaxAge else { continue }
            try? fileManager.removeItem(at: child)
        }
    }

    func removeQuarantineAttribute(at url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            "com.apple.quarantine".withCString { attribute in
                _ = Darwin.removexattr(path, attribute, 0)
            }
        }
    }

    // MARK: - Manifest payloads

    struct AuthorPayload: Encodable {
        let name: String
    }

    struct InterfacePayload: Encodable {
        let displayName: String
        let shortDescription: String
        let longDescription: String
        let developerName: String
        let category: String
        let capabilities: [String]
        let defaultPrompt: [String]
    }

    struct CodexManifestPayload: Encodable {
        let name: String
        let version: String
        let description: String
        let author: AuthorPayload
        let skills: String
        let interface: InterfacePayload
    }

    struct ClaudeManifestPayload: Encodable {
        let name: String
        let version: String
        let description: String
        let author: AuthorPayload
    }

    struct CursorManifestPayload: Encodable {
        let name: String
        let version: String
        let description: String
        let author: AuthorPayload
        let skills: String
    }

    struct MarketplaceInterfacePayload: Encodable {
        let displayName: String
    }

    struct MarketplaceSourcePayload: Encodable {
        let source: String
        let path: String
    }

    struct MarketplacePolicyPayload: Encodable {
        let installation: String
        let authentication: String
    }

    struct MarketplacePluginEntryPayload: Encodable {
        let name: String
        let source: MarketplaceSourcePayload
        let policy: MarketplacePolicyPayload
        let category: String
    }

    struct MarketplacePayload: Encodable {
        let name: String
        let interface: MarketplaceInterfacePayload
        let plugins: [MarketplacePluginEntryPayload]
    }
}
