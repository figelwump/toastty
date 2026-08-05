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

/// Standalone catalog for user-created skill packages under the runtime
/// paths' `skills` directory. `scan()` is read-only; `prepareSnapshot()`
/// builds (or reuses) an immutable content-addressed `toastty-user` plugin
/// snapshot under `<agent-plugins>/user/<sourceDigest>/`. Delivery wiring is
/// a separate concern; this type never touches launch paths and never reads
/// `~/.codex`, `~/.claude`, or `~/.agents`.
final class ToasttyUserSkillCatalog: @unchecked Sendable {
    private let userSkillsDirectoryURL: URL
    private let snapshotsRootURL: URL
    private let fileManager: FileManager

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
    /// packages. Returns nil (and creates nothing) when no package is
    /// accepted; the delivery phase interprets nil as "no user plugin".
    func prepareSnapshot() throws -> UserSkillPluginSnapshot? {
        cleanupOrphanedStaging()
        let scanResult = validator.scan(userSkillsDirectoryURL: userSkillsDirectoryURL)
        let payloads = scanResult.acceptedPayloads
        guard payloads.isEmpty == false else { return nil }

        let sourceDigest = try Self.sourceDigest(payloads: payloads, fileManager: fileManager)
        let version = Self.version(sourceDigest: sourceDigest)
        let destinationURL = snapshotsRootURL.appendingPathComponent(sourceDigest, isDirectory: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            if let existing = try? verifiedSnapshot(at: destinationURL, sourceDigest: sourceDigest) {
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
    /// out-of-package bytes into a snapshot.
    static func readRegularFileNoFollow(at url: URL) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW)
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
        let marketplaceManifestURL = marketplaceRootURL
            .appendingPathComponent(".agents/plugins", isDirectory: true)
            .appendingPathComponent("marketplace.json")
        for (url, data) in [
            (codexManifestURL, try encodeJSON(codexManifest)),
            (claudeManifestURL, try encodeJSON(claudeManifest)),
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
