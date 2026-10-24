import CoreState
import Combine
import Darwin
import Foundation

/// Review records and evidence use the runtime config paths chosen by app assembly.
/// Every transaction reaches disk before the published state changes.
@MainActor
final class CoordinatorReviewStore: ObservableObject {
    static let maximumItemCount = 10_000
    static let maximumSnapshotBytes = 32 * 1_024 * 1_024
    static let maximumEvidenceFileBytes = 8 * 1_024 * 1_024
    static let maximumStoredEvidenceFiles = 1_024
    static let maximumStoredEvidenceBytes = 256 * 1_024 * 1_024

    enum StoreError: Error, Equatable, LocalizedError {
        case storeUnavailable(String)
        case itemNotFound(UUID)
        case revisionMismatch(expected: Int, actual: Int)
        case acceptedPublicationConflict(UUID)
        case invalidPublication(String)
        case identityChanged
        case evidenceUnavailable(String)
        case evidenceLimitExceeded

        var errorDescription: String? {
            switch self {
            case .storeUnavailable(let reason): "Review storage is unavailable: \(reason)"
            case .itemNotFound(let id): "Review \(id) was not found."
            case .revisionMismatch(let expected, let actual): "Review revision changed from \(expected) to \(actual). Refresh before deciding."
            case .acceptedPublicationConflict: "The accepted review brief cannot be replaced. Publish a new PR head for a new decision."
            case .invalidPublication(let reason): "Invalid review publication: \(reason)"
            case .identityChanged: "A review transaction cannot change its identity."
            case .evidenceUnavailable(let reason): "Review evidence is unavailable: \(reason)"
            case .evidenceLimitExceeded: "Review evidence exceeds the storage limit."
            }
        }
    }

    /// A transient source for one evidence entry. Its path is never encoded.
    struct EvidenceFile {
        let evidenceIndex: Int
        let fileURL: URL

        init(evidenceIndex: Int, fileURL: URL) {
            self.evidenceIndex = evidenceIndex
            self.fileURL = fileURL
        }
    }

    @Published private(set) var items: [CoordinatorReviewItem]
    @Published private(set) var queue: [CoordinatorReviewQueueEntry] = []
    /// A load failure blocks every write. The original file stays untouched.
    @Published private(set) var loadError: String?

    private let fileURL: URL?
    private let evidenceDirectoryURL: URL?
    private var taskFacts: [CoordinatorReviewTaskFacts] = []
    private static let snapshotVersion = 1

    static func inMemory() -> CoordinatorReviewStore {
        CoordinatorReviewStore(fileURL: nil)
    }

    init(fileURL: URL?, evidenceDirectoryURL: URL? = nil) {
        self.fileURL = fileURL
        self.evidenceDirectoryURL = evidenceDirectoryURL
            ?? fileURL?.deletingLastPathComponent().appendingPathComponent("coordinator-review-evidence", isDirectory: true)
        do {
            items = try Self.load(from: fileURL)
            loadError = nil
        } catch {
            items = []
            loadError = error.localizedDescription
        }
    }

    func item(id: UUID) -> CoordinatorReviewItem? {
        items.first { $0.id == id }
    }

    /// Native facts are ephemeral. Reconciliation never writes PR observations
    /// or changes a recorded user decision.
    func reconcile(_ facts: [CoordinatorReviewTaskFacts]) {
        var seen: Set<UUID> = []
        taskFacts = facts.filter { seen.insert($0.taskID).inserted }
        rebuildQueue()
    }

    /// Deduplicates task/PR/head/base publications. A new head or base gets a new record and
    /// no user decision. Agent publications cannot supply decisions or outcomes.
    @discardableResult
    func upsertPublication(
        _ publication: CoordinatorReviewItem,
        evidenceFiles: [EvidenceFile] = []
    ) throws -> CoordinatorReviewItem {
        try requireWritable()
        try publication.validate()
        guard publication.userAction == nil, publication.actionHistory == nil,
              publication.observedOutcome == .init(), publication.priorityOverride == nil else {
            throw StoreError.invalidPublication("Only the native user surface records decisions; PR observation records outcomes.")
        }
        guard publication.brief.evidence.allSatisfy({ $0.managedFileName == nil }) else {
            throw StoreError.invalidPublication("Managed evidence names are assigned only by the store.")
        }
        let existingIndex = items.firstIndex { Self.samePublication($0, publication) }
        var acceptedReviewID: UUID?
        if let existingIndex {
            let existing = items[existingIndex]
            guard existing.projectRoot == publication.projectRoot else { throw StoreError.identityChanged }
            if existing.userAction != nil || existing.actionHistory?.isEmpty == false {
                guard Self.briefMetadata(existing.brief) == publication.brief else {
                    throw StoreError.acceptedPublicationConflict(existing.id)
                }
                acceptedReviewID = existing.id
            }
        } else if items.contains(where: { $0.id == publication.id }) {
            throw StoreError.identityChanged
        }
        if existingIndex == nil, items.count >= Self.maximumItemCount {
            throw StoreError.invalidPublication("Too many stored reviews.")
        }

        var candidate = publication
        var copiedFiles: [URL] = []
        var committed = false
        defer {
            if !committed { for file in copiedFiles { try? FileManager.default.removeItem(at: file) } }
        }
        candidate.brief.evidence = try prepareEvidence(
            publication.brief.evidence, files: evidenceFiles,
            existingEvidence: existingIndex.map { items[$0].brief.evidence } ?? [],
            acceptedReviewID: acceptedReviewID, copiedFiles: &copiedFiles
        )
        if let existingIndex, acceptedReviewID != nil {
            guard candidate.brief == items[existingIndex].brief else {
                throw StoreError.acceptedPublicationConflict(items[existingIndex].id)
            }
            return items[existingIndex]
        }
        let now = Date()
        var next = items
        let result: CoordinatorReviewItem
        if let existingIndex {
            var existing = next[existingIndex]
            existing.brief = candidate.brief
            existing.taskTitle = candidate.taskTitle
            if existing == next[existingIndex] { return existing }
            existing.revision = try increment(existing.revision)
            existing.updatedAt = max(now, existing.createdAt)
            next[existingIndex] = existing
            result = existing
        } else {
            candidate.revision = 1
            next.append(candidate)
            result = candidate
        }
        try commit(next)
        committed = true
        removeUnreferencedEvidence(from: items)
        return result
    }

    /// Optimistic transaction for native decisions, delivery and observation.
    /// The caller owns action-transition rules; this store protects identity,
    /// the brief and prior intents, validation, and persistence before publication.
    @discardableResult
    func update(
        id: UUID,
        expectedRevision: Int,
        _ body: (inout CoordinatorReviewItem) throws -> Void
    ) throws -> CoordinatorReviewItem {
        try requireWritable()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw StoreError.itemNotFound(id) }
        let previous = items[index]
        guard previous.revision == expectedRevision else {
            throw StoreError.revisionMismatch(expected: expectedRevision, actual: previous.revision)
        }
        var candidate = previous
        try body(&candidate)
        guard Self.sameIdentity(previous, candidate), candidate.revision == previous.revision else {
            throw StoreError.identityChanged
        }
        guard candidate.brief == previous.brief else {
            throw StoreError.invalidPublication("Native transactions cannot change a review brief.")
        }
        guard candidate.actionHistory == previous.actionHistory else {
            throw StoreError.invalidPublication("Native transactions cannot rewrite prior user intents.")
        }
        if let priorAction = previous.userAction, priorAction.intentID != candidate.userAction?.intentID {
            var history = previous.actionHistory ?? []
            guard history.count < CoordinatorReviewItem.maximumActionHistoryCount else {
                throw StoreError.invalidPublication("User intent history limit reached.")
            }
            history.append(priorAction)
            candidate.actionHistory = history
        }
        guard candidate != previous else { return previous }
        candidate.revision = try increment(previous.revision)
        candidate.updatedAt = max(Date(), previous.createdAt)
        try candidate.validate()
        var next = items
        next[index] = candidate
        try commit(next)
        return candidate
    }

    /// Resolves only store-generated direct children that remain regular files.
    func managedEvidenceURL(for evidence: CoordinatorReviewEvidence) -> URL? {
        guard let root = evidenceDirectoryURL, let name = evidence.managedFileName,
              CoordinatorReviewEvidence.isValidManagedFileName(name), Self.isDirectory(root) else { return nil }
        let url = root.appendingPathComponent(name, isDirectory: false)
        guard Self.isRegularFile(url, maximumBytes: Self.maximumEvidenceFileBytes) else { return nil }
        return url
    }

    private func requireWritable() throws {
        if let loadError { throw StoreError.storeUnavailable(loadError) }
    }

    private func increment(_ revision: Int) throws -> Int {
        guard revision < Int.max else { throw StoreError.invalidPublication("Revision limit reached.") }
        return revision + 1
    }

    private func commit(_ next: [CoordinatorReviewItem]) throws {
        try requireWritable()
        try Self.validateSnapshot(next)
        if let fileURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            // Default date coding preserves fractional seconds on restart.
            let data = try encoder.encode(Snapshot(version: Self.snapshotVersion, items: next))
            guard data.count <= Self.maximumSnapshotBytes else { throw StoreError.storeUnavailable("Snapshot limit reached.") }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var info = stat()
            if lstat(fileURL.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG else { throw StoreError.storeUnavailable("Snapshot is not a regular file.") }
            } else if errno != ENOENT {
                throw StoreError.storeUnavailable("Cannot inspect the snapshot file.")
            }
            try data.write(to: fileURL, options: [.atomic])
        }
        items = next
        rebuildQueue()
    }

    private func rebuildQueue() {
        queue = taskFacts.compactMap { facts in
            let review = items.first {
                $0.taskID == facts.taskID && $0.projectRoot == facts.projectRoot
                    && $0.pullRequestURL.lowercased() == facts.pullRequestURL?.lowercased()
                    && $0.headSHA.lowercased() == facts.headSHA?.lowercased()
                    && $0.baseRefName == facts.baseRefName
            }
            let entry = CoordinatorReviewQueueEntry(facts: facts, review: review)
            return facts.needsReview || entry.hasPendingAction ? entry : nil
        }.sorted {
            let lhsPriority = Self.priorityOrder($0.effectivePriority)
            let rhsPriority = Self.priorityOrder($1.effectivePriority)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            let lhsDate = $0.review?.createdAt ?? .distantPast
            let rhsDate = $1.review?.createdAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            let lhsTitle = $0.facts.taskTitle.lowercased()
            let rhsTitle = $1.facts.taskTitle.lowercased()
            if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
            return $0.taskID.uuidString < $1.taskID.uuidString
        }
    }

    private static func priorityOrder(_ value: CoordinatorReviewBrief.Priority) -> Int {
        switch value {
        case .urgent: 0
        case .blocking: 1
        case .ready: 2
        }
    }

    private static func load(from fileURL: URL?) throws -> [CoordinatorReviewItem] {
        guard let fileURL else { return [] }
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else {
            if errno == ENOENT { return [] }
            throw StoreError.storeUnavailable("Cannot inspect the snapshot file.")
        }
        guard fileURL.isFileURL, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumSnapshotBytes else {
            throw StoreError.storeUnavailable("Snapshot is not a bounded regular file.")
        }
        let data = try readRegularFile(fileURL, maximumBytes: maximumSnapshotBytes)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == snapshotVersion else {
            throw StoreError.storeUnavailable("Unsupported snapshot version \(snapshot.version).")
        }
        try validateSnapshot(snapshot.items)
        return snapshot.items
    }

    private static func validateSnapshot(_ items: [CoordinatorReviewItem]) throws {
        guard items.count <= maximumItemCount, Set(items.map(\.id)).count == items.count else {
            throw StoreError.invalidPublication("Duplicate review identities or too many reviews.")
        }
        var publicationKeys: Set<String> = []
        var intentIDs: Set<UUID> = []
        for item in items {
            try item.validate()
            let key = "\(item.taskID)|\(item.pullRequestURL.lowercased())|\(item.headSHA.lowercased())|\(item.baseRefName ?? "")"
            guard publicationKeys.insert(key).inserted else { throw StoreError.invalidPublication("Duplicate task, PR, head and base.") }
            for action in (item.actionHistory ?? []) + [item.userAction].compactMap({ $0 }) {
                guard intentIDs.insert(action.intentID).inserted else {
                    throw StoreError.invalidPublication("Duplicate user intent identity.")
                }
            }
        }
    }

    private static func sameTaskPR(_ lhs: CoordinatorReviewItem, _ rhs: CoordinatorReviewItem) -> Bool {
        lhs.taskID == rhs.taskID && lhs.repository.lowercased() == rhs.repository.lowercased()
            && lhs.pullRequestURL.lowercased() == rhs.pullRequestURL.lowercased()
    }

    private static func samePublication(_ lhs: CoordinatorReviewItem, _ rhs: CoordinatorReviewItem) -> Bool {
        sameTaskPR(lhs, rhs) && lhs.headSHA.lowercased() == rhs.headSHA.lowercased()
            && lhs.baseRefName == rhs.baseRefName
    }

    private static func sameIdentity(_ lhs: CoordinatorReviewItem, _ rhs: CoordinatorReviewItem) -> Bool {
        lhs.id == rhs.id && lhs.taskID == rhs.taskID && lhs.projectRoot == rhs.projectRoot
            && lhs.repository == rhs.repository && lhs.pullRequestURL == rhs.pullRequestURL
            && lhs.headSHA == rhs.headSHA && lhs.baseRefName == rhs.baseRefName && lhs.createdAt == rhs.createdAt
    }

    private static func briefMetadata(_ brief: CoordinatorReviewBrief) -> CoordinatorReviewBrief {
        var value = brief
        value.evidence = brief.evidence.map(evidenceMetadata)
        return value
    }

    private static func evidenceMetadata(_ evidence: CoordinatorReviewEvidence) -> CoordinatorReviewEvidence {
        var value = evidence
        value.managedFileName = nil
        return value
    }

    private struct Snapshot: Codable {
        var version: Int
        var items: [CoordinatorReviewItem]
    }
}

private extension CoordinatorReviewStore {
    func prepareEvidence(
        _ evidence: [CoordinatorReviewEvidence], files: [EvidenceFile],
        existingEvidence: [CoordinatorReviewEvidence], acceptedReviewID: UUID?, copiedFiles: inout [URL]
    ) throws -> [CoordinatorReviewEvidence] {
        guard files.count <= CoordinatorReviewBrief.maximumEvidenceCount,
              Set(files.map(\.evidenceIndex)).count == files.count,
              files.allSatisfy({ evidence.indices.contains($0.evidenceIndex) }) else {
            throw StoreError.invalidPublication("Invalid evidence file indices or count.")
        }
        var usage: (count: Int, bytes: Int)?
        var result = evidence
        for index in evidence.indices {
            let prior = existingEvidence.indices.contains(index)
                && Self.evidenceMetadata(existingEvidence[index]) == evidence[index] ? existingEvidence[index] : nil
            guard let file = files.first(where: { $0.evidenceIndex == index }) else {
                // A metadata-only replay retains the durable reference. Missing
                // files remain visible as missing; they do not erase the record.
                result[index].managedFileName = prior?.managedFileName
                continue
            }
            let bytes = try Self.readRegularFile(file.fileURL, maximumBytes: Self.maximumEvidenceFileBytes)
            if let prior, let url = managedEvidenceURL(for: prior),
               bytes == (try? Self.readRegularFile(url, maximumBytes: Self.maximumEvidenceFileBytes)) {
                result[index].managedFileName = prior.managedFileName
                continue
            }
            if let acceptedReviewID { throw StoreError.acceptedPublicationConflict(acceptedReviewID) }
            guard let root = evidenceDirectoryURL else { throw StoreError.evidenceUnavailable("No evidence directory is configured.") }
            if usage == nil {
                try prepareEvidenceDirectory(root)
                usage = try evidenceUsage(root)
            }
            guard var currentUsage = usage, currentUsage.count < Self.maximumStoredEvidenceFiles,
                  bytes.count <= Self.maximumStoredEvidenceBytes - currentUsage.bytes else { throw StoreError.evidenceLimitExceeded }
            let sourceExtension = file.fileURL.pathExtension.lowercased()
            let suffix = !sourceExtension.isEmpty && sourceExtension.count <= 12
                && sourceExtension.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) })
                ? "." + sourceExtension : ""
            let name = UUID().uuidString + suffix
            let destination = root.appendingPathComponent(name, isDirectory: false)
            // O_EXCL and O_NOFOLLOW ensure a copy never replaces or follows a link.
            let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw StoreError.evidenceUnavailable("Cannot create a managed copy.") }
            copiedFiles.append(destination)
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            try handle.close()
            result[index].managedFileName = name
            currentUsage.count += 1
            currentUsage.bytes += bytes.count
            usage = currentUsage
        }
        return result
    }

    func prepareEvidenceDirectory(_ root: URL) throws {
        guard root.isFileURL else { throw StoreError.evidenceUnavailable("Use a local evidence directory.") }
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if mkdir(root.path, 0o700) != 0, errno != EEXIST { throw StoreError.evidenceUnavailable("Cannot create the evidence directory.") }
        guard Self.isDirectory(root) else { throw StoreError.evidenceUnavailable("Evidence storage is not a directory.") }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    static func isRegularFile(_ url: URL, maximumBytes: Int) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_size >= 0 && info.st_size <= maximumBytes
    }

    static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else {
            throw StoreError.evidenceUnavailable("Use an absolute file path without traversal.")
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw StoreError.evidenceUnavailable("Cannot open a regular source file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw StoreError.evidenceLimitExceeded }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw StoreError.evidenceLimitExceeded }
        return data
    }

    func evidenceUsage(_ root: URL) throws -> (count: Int, bytes: Int) {
        var count = 0
        var bytes = 0
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard CoordinatorReviewEvidence.isValidManagedFileName(file.lastPathComponent),
                  Self.isRegularFile(file, maximumBytes: Self.maximumEvidenceFileBytes) else {
                throw StoreError.evidenceUnavailable("Unexpected file in the evidence directory.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard count < Self.maximumStoredEvidenceFiles, size <= Self.maximumStoredEvidenceBytes - bytes else {
                throw StoreError.evidenceLimitExceeded
            }
            count += 1
            bytes += size
        }
        return (count, bytes)
    }

    /// Runs only after a successful snapshot write. Failed transactions remove
    /// only their new copies and leave all earlier evidence untouched.
    func removeUnreferencedEvidence(from items: [CoordinatorReviewItem]) {
        guard let root = evidenceDirectoryURL, Self.isDirectory(root),
              let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let names = Set(items.flatMap { $0.brief.evidence.compactMap(\.managedFileName) })
        for file in files where CoordinatorReviewEvidence.isValidManagedFileName(file.lastPathComponent)
            && !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
