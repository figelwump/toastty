import CryptoKit
import Foundation

/// Typed reason a user skill package (or the whole catalog) was excluded.
/// Display messages never include skill file contents; callers pair them with
/// the package name or path only.
enum UserSkillDiagnostic: String, Equatable, Sendable, CaseIterable {
    case invalidName
    case nameMismatch
    case duplicateName
    case symlinkRejected
    case specialFileRejected
    case unreadable
    case packageTooLarge
    case skillFileTooLarge
    case depthExceeded
    case globalLimitExceeded
    case missingSkillFile
    case invalidFrontmatter

    var code: String { rawValue }

    var displayMessage: String {
        switch self {
        case .invalidName:
            return "The skill name must start with a lowercase letter or digit and use only lowercase letters, digits, and hyphens (64 characters max)."
        case .nameMismatch:
            return "The skill folder name and the SKILL.md frontmatter name must match."
        case .duplicateName:
            return "Another skill package uses the same name; every package with this name was excluded."
        case .symlinkRejected:
            return "Symbolic links are not allowed in skill packages."
        case .specialFileRejected:
            return "Skill packages may only contain regular files and folders."
        case .unreadable:
            return "Toastty could not read part of this skill package."
        case .packageTooLarge:
            return "The skill package exceeds the 5 MB size limit."
        case .skillFileTooLarge:
            return "SKILL.md exceeds the 256 KB size limit."
        case .depthExceeded:
            return "The skill package folder structure is nested too deeply (8 levels max)."
        case .globalLimitExceeded:
            return "The combined user skills exceed the catalog limits (32 packages, 10 MB, 500 files); all user skills were excluded."
        case .missingSkillFile:
            return "The skill package is missing a SKILL.md file at its root."
        case .invalidFrontmatter:
            return "SKILL.md must start with YAML frontmatter containing a name and a non-empty description."
        }
    }
}

struct UserSkillPackage: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case accepted
        case excluded(UserSkillDiagnostic)
    }

    /// Canonical (NFC-normalized) package name derived from the directory
    /// basename.
    let name: String
    let sourceURL: URL
    let status: Status

    var isAccepted: Bool { status == .accepted }
}

struct UserSkillCatalogState: Equatable, Sendable {
    let packages: [UserSkillPackage]
    let globalDiagnostics: [UserSkillDiagnostic]
    /// Cheap change-detection roll-up over the scanned sources (sorted names
    /// plus per-package file-count/size/mtime aggregates). Not a content
    /// digest.
    let sourceFingerprint: String

    var acceptedPackages: [UserSkillPackage] {
        packages.filter(\.isAccepted)
    }
}

/// Scan output consumed by the snapshot builder: the public state plus the
/// exact per-file payload inventory of every accepted package.
struct ToasttyUserSkillScanResult {
    struct PayloadFile: Equatable, Sendable {
        let relativePath: String
        let sourceURL: URL
        let isExecutable: Bool
        let size: Int
    }

    struct PackagePayload: Equatable, Sendable {
        /// Canonical NFC name; also the destination directory name, so NFD
        /// source directories produce byte-identical snapshots.
        let name: String
        let sourceURL: URL
        /// Sorted by `relativePath`.
        let files: [PayloadFile]
    }

    let state: UserSkillCatalogState
    /// Sorted by package name. Empty whenever a global limit tripped.
    let acceptedPayloads: [PackagePayload]
}

/// Read-only validation of `~/.toastty/skills` (or its runtime-isolated
/// equivalent). Performs no writes.
struct ToasttyUserSkillValidator {
    static let maxNameLength = 64
    static let maxSkillFileBytes = 256 * 1024
    static let maxPackageBytes = 5 * 1024 * 1024
    static let maxEntryDepth = 8
    static let maxAcceptedPackages = 32
    static let maxAcceptedTotalBytes = 10 * 1024 * 1024
    static let maxAcceptedTotalFiles = 500

    let fileManager: FileManager

    func scan(userSkillsDirectoryURL: URL) -> ToasttyUserSkillScanResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: userSkillsDirectoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let childNames = try? fileManager.contentsOfDirectory(atPath: userSkillsDirectoryURL.path) else {
            // A missing (or unreadable) source directory is an empty catalog,
            // not an error.
            return ToasttyUserSkillScanResult(
                state: UserSkillCatalogState(
                    packages: [],
                    globalDiagnostics: [],
                    sourceFingerprint: Self.fingerprint(lines: [])
                ),
                acceptedPayloads: []
            )
        }

        var evaluations: [PackageEvaluation] = []
        var acceptedCount = 0
        var acceptedBytes = 0
        var acceptedFiles = 0
        var globalCapBreached = false
        for childName in childNames.sorted() {
            guard childName.hasPrefix(".") == false else { continue }
            let childURL = userSkillsDirectoryURL.appendingPathComponent(childName, isDirectory: true)
            guard let type = entryType(atPath: childURL.path) else { continue }
            switch type {
            case .typeSymbolicLink:
                // A symlinked package directory is a visible rejection, unlike
                // other non-directory children, which are silently ignored.
                evaluations.append(PackageEvaluation(
                    name: childName.precomposedStringWithCanonicalMapping,
                    sourceURL: childURL,
                    status: .excluded(.symlinkRejected),
                    inventory: WalkInventory()
                ))
            case .typeDirectory:
                // Once a global cap is breached the outcome is all-excluded;
                // remaining packages are recorded without walking their
                // contents so a pathological source tree cannot stretch the
                // scan unboundedly.
                if globalCapBreached {
                    evaluations.append(PackageEvaluation(
                        name: childName.precomposedStringWithCanonicalMapping,
                        sourceURL: childURL,
                        status: .excluded(.globalLimitExceeded),
                        inventory: WalkInventory()
                    ))
                    continue
                }
                let evaluation = evaluatePackage(at: childURL)
                if evaluation.status == .accepted {
                    acceptedCount += 1
                    acceptedBytes += evaluation.inventory.totalBytes
                    acceptedFiles += evaluation.inventory.fileCount
                    if acceptedCount > Self.maxAcceptedPackages
                        || acceptedBytes > Self.maxAcceptedTotalBytes
                        || acceptedFiles > Self.maxAcceptedTotalFiles {
                        globalCapBreached = true
                    }
                }
                evaluations.append(evaluation)
            default:
                continue
            }
        }

        markDuplicates(&evaluations)
        evaluations.sort { $0.name < $1.name }

        var acceptedPayloads = evaluations
            .filter { $0.status == .accepted }
            .map { evaluation in
                ToasttyUserSkillScanResult.PackagePayload(
                    name: evaluation.name,
                    sourceURL: evaluation.sourceURL,
                    files: evaluation.inventory.files.sorted { $0.relativePath < $1.relativePath }
                )
            }
        var globalDiagnostics: [UserSkillDiagnostic] = []

        let acceptedInventories = evaluations.filter { $0.status == .accepted }.map(\.inventory)
        let totalBytes = acceptedInventories.reduce(0) { $0 + $1.totalBytes }
        let totalFiles = acceptedInventories.reduce(0) { $0 + $1.fileCount }
        if globalCapBreached
            || acceptedPayloads.count > Self.maxAcceptedPackages
            || totalBytes > Self.maxAcceptedTotalBytes
            || totalFiles > Self.maxAcceptedTotalFiles {
            // Deterministic all-or-nothing: a breached global cap excludes
            // every user package for this preparation.
            for index in evaluations.indices where evaluations[index].status == .accepted {
                evaluations[index].status = .excluded(.globalLimitExceeded)
            }
            globalDiagnostics.append(.globalLimitExceeded)
            acceptedPayloads = []
        }

        let packages = evaluations.map { evaluation in
            UserSkillPackage(
                name: evaluation.name,
                sourceURL: evaluation.sourceURL,
                status: evaluation.status
            )
        }
        let fingerprintLines = evaluations.map { evaluation in
            [
                evaluation.name,
                String(evaluation.inventory.fileCount),
                String(evaluation.inventory.totalBytes),
                String(Int(evaluation.inventory.latestModification * 1000)),
            ].joined(separator: "|")
        }
        return ToasttyUserSkillScanResult(
            state: UserSkillCatalogState(
                packages: packages,
                globalDiagnostics: globalDiagnostics,
                sourceFingerprint: Self.fingerprint(lines: fingerprintLines)
            ),
            acceptedPayloads: acceptedPayloads
        )
    }
}

private extension ToasttyUserSkillValidator {
    struct WalkInventory {
        var files: [ToasttyUserSkillScanResult.PayloadFile] = []
        var totalBytes = 0
        var fileCount = 0
        var latestModification: TimeInterval = 0
    }

    struct PackageEvaluation {
        let name: String
        let sourceURL: URL
        var status: UserSkillPackage.Status
        var inventory: WalkInventory

        var collisionKey: String {
            name
                .folding(options: .caseInsensitive, locale: nil)
                .precomposedStringWithCanonicalMapping
        }
    }

    func entryType(atPath path: String) -> FileAttributeType? {
        // attributesOfItem does not traverse symlinks (lstat semantics).
        (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
    }

    func evaluatePackage(at packageURL: URL) -> PackageEvaluation {
        let canonicalName = packageURL.lastPathComponent.precomposedStringWithCanonicalMapping
        var inventory = WalkInventory()
        if let rootModification = (try? fileManager.attributesOfItem(atPath: packageURL.path))?[.modificationDate] as? Date {
            inventory.latestModification = rootModification.timeIntervalSince1970
        }

        func evaluation(_ status: UserSkillPackage.Status) -> PackageEvaluation {
            PackageEvaluation(
                name: canonicalName,
                sourceURL: packageURL,
                status: status,
                inventory: inventory
            )
        }

        if let violation = walkDirectory(
            at: packageURL,
            relativePath: "",
            depth: 0,
            standardizedRootPath: packageURL.standardizedFileURL.path,
            into: &inventory
        ) {
            return evaluation(.excluded(violation))
        }

        guard let skillFile = inventory.files.first(where: { $0.relativePath == "SKILL.md" }) else {
            return evaluation(.excluded(.missingSkillFile))
        }
        guard skillFile.size <= Self.maxSkillFileBytes else {
            return evaluation(.excluded(.skillFileTooLarge))
        }
        guard let contents = try? String(contentsOf: skillFile.sourceURL, encoding: .utf8) else {
            return evaluation(.excluded(.unreadable))
        }
        guard let frontmatter = Self.parseFrontmatter(contents) else {
            return evaluation(.excluded(.invalidFrontmatter))
        }
        guard frontmatter.name.precomposedStringWithCanonicalMapping == canonicalName else {
            return evaluation(.excluded(.nameMismatch))
        }
        guard Self.isValidCanonicalName(canonicalName) else {
            return evaluation(.excluded(.invalidName))
        }
        guard inventory.totalBytes <= Self.maxPackageBytes else {
            return evaluation(.excluded(.packageTooLarge))
        }
        return evaluation(.accepted)
    }

    /// Depth-first lstat-based walk. Returns the first violation, or nil after
    /// filling `inventory` with every regular file.
    func walkDirectory(
        at directoryURL: URL,
        relativePath: String,
        depth: Int,
        standardizedRootPath: String,
        into inventory: inout WalkInventory
    ) -> UserSkillDiagnostic? {
        guard let childNames = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return .unreadable
        }
        for childName in childNames.sorted() {
            let childURL = directoryURL.appendingPathComponent(childName)
            let childRelativePath = relativePath.isEmpty ? childName : relativePath + "/" + childName
            let childDepth = depth + 1
            // Defense in depth: a path component must never resolve outside
            // the package root.
            guard childURL.standardizedFileURL.path.hasPrefix(standardizedRootPath + "/") else {
                return .unreadable
            }
            guard let attributes = try? fileManager.attributesOfItem(atPath: childURL.path),
                  let type = attributes[.type] as? FileAttributeType else {
                return .unreadable
            }
            if type == .typeSymbolicLink {
                return .symlinkRejected
            }
            if childDepth > Self.maxEntryDepth {
                return .depthExceeded
            }
            if let modification = attributes[.modificationDate] as? Date {
                inventory.latestModification = max(
                    inventory.latestModification,
                    modification.timeIntervalSince1970
                )
            }
            switch type {
            case .typeDirectory:
                if let violation = walkDirectory(
                    at: childURL,
                    relativePath: childRelativePath,
                    depth: childDepth,
                    standardizedRootPath: standardizedRootPath,
                    into: &inventory
                ) {
                    return violation
                }
            case .typeRegular:
                guard fileManager.isReadableFile(atPath: childURL.path) else {
                    return .unreadable
                }
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                inventory.files.append(ToasttyUserSkillScanResult.PayloadFile(
                    relativePath: childRelativePath,
                    sourceURL: childURL,
                    isExecutable: permissions & 0o111 != 0,
                    size: size
                ))
                inventory.totalBytes += size
                inventory.fileCount += 1
                // Abort the walk as soon as the package breaches its byte cap
                // so an oversized tree cannot stretch scanning unboundedly.
                if inventory.totalBytes > Self.maxPackageBytes {
                    return .packageTooLarge
                }
            default:
                return .specialFileRejected
            }
        }
        return nil
    }

    func markDuplicates(_ evaluations: inout [PackageEvaluation]) {
        var indicesByKey: [String: [Int]] = [:]
        for (index, evaluation) in evaluations.enumerated() {
            indicesByKey[evaluation.collisionKey, default: []].append(index)
        }
        for indices in indicesByKey.values where indices.count >= 2 {
            // A case-folded collision excludes every colliding package,
            // regardless of any other diagnostic the members carried.
            for index in indices {
                evaluations[index].status = .excluded(.duplicateName)
            }
        }
    }

    /// `[a-z0-9][a-z0-9-]*`, at most 64 characters, applied to the NFC form.
    static func isValidCanonicalName(_ name: String) -> Bool {
        guard name.isEmpty == false, name.count <= maxNameLength else { return false }
        func isLowercaseAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
        }
        let scalars = name.unicodeScalars
        guard let first = scalars.first, isLowercaseAlphanumeric(first) else { return false }
        return scalars.dropFirst().allSatisfy { isLowercaseAlphanumeric($0) || $0 == "-" }
    }

    /// Minimal hand-parse of the simple `key: value` frontmatter shape the
    /// shipped skills use (see scripts/agents/validate-toastty-plugin.py):
    /// a leading `---` line, top-level keys, and a closing `---` line.
    /// Lines are split on any newline Character — Swift treats CRLF as a
    /// single grapheme, so splitting on "\n" alone would never split CRLF
    /// files — and a leading UTF-8 BOM is stripped.
    static func parseFrontmatter(_ contents: String) -> (name: String, description: String)? {
        var contents = contents
        if contents.hasPrefix("\u{FEFF}") {
            contents.removeFirst()
        }
        let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
        var name: String?
        var description: String?
        var closed = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" {
                closed = true
                break
            }
            guard line.first?.isWhitespace != true,
                  let colonIndex = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<colonIndex])
            let value = unquoted(
                String(line[line.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            switch key {
            case "name": name = value
            case "description": description = value
            default: break
            }
        }
        guard closed,
              let name, name.isEmpty == false,
              let description, description.isEmpty == false else {
            return nil
        }
        return (name, description)
    }

    static func unquoted(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    static func fingerprint(lines: [String]) -> String {
        var hasher = SHA256()
        for line in lines {
            hasher.update(data: Data("pkg:\(line.utf8.count):\(line)".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
