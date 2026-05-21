import CoreState
import Foundation

enum ScratchpadDocumentContentType: String, Codable, Equatable, Sendable {
    case html
}

struct ScratchpadDocument: Codable, Equatable, Sendable {
    let documentID: UUID
    var revision: Int
    var title: String?
    var contentType: ScratchpadDocumentContentType
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var sessionLink: ScratchpadSessionLink?
}

struct ScratchpadContentPatch: Codable, Equatable, Sendable {
    var replacements: [ScratchpadContentReplacement]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case replacements
    }

    init(replacements: [ScratchpadContentReplacement]) {
        self.replacements = replacements
    }

    init(from decoder: Decoder) throws {
        try ScratchpadPatchStrictDecoding.rejectUnknownKeys(
            decoder: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replacements = try container.decode([ScratchpadContentReplacement].self, forKey: .replacements)
    }
}

struct ScratchpadContentReplacement: Codable, Equatable, Sendable {
    var oldText: String
    var newText: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case oldText
        case newText
    }

    init(oldText: String, newText: String) {
        self.oldText = oldText
        self.newText = newText
    }

    init(from decoder: Decoder) throws {
        try ScratchpadPatchStrictDecoding.rejectUnknownKeys(
            decoder: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.stringValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        oldText = try container.decode(String.self, forKey: .oldText)
        newText = try container.decode(String.self, forKey: .newText)
    }
}

struct ScratchpadDocumentPatchOutcome: Equatable, Sendable {
    let document: ScratchpadDocument
    let documentID: UUID
    let previousRevision: Int
    let revision: Int
    let appliedEditCount: Int
}

enum ScratchpadDocumentStoreError: LocalizedError, Equatable {
    case contentTooLarge(maxBytes: Int, actualBytes: Int)
    case patchTooLarge(maxBytes: Int, actualBytes: Int)
    case invalidPatch(String)
    case emptyPatch
    case emptyOldText(replacementIndex: Int)
    case oldTextNotFound(replacementIndex: Int)
    case oldTextNotUnique(replacementIndex: Int, matchCount: Int)
    case staleRevision(expectedRevision: Int, currentRevision: Int)
    case missingDocument(UUID)

    var errorDescription: String? {
        switch self {
        case .contentTooLarge(let maxBytes, let actualBytes):
            return "scratchpad content is too large (\(actualBytes) bytes, maximum \(maxBytes) bytes)"
        case .patchTooLarge(let maxBytes, let actualBytes):
            return "scratchpad patch is too large (\(actualBytes) bytes, maximum \(maxBytes) bytes)"
        case .invalidPatch(let reason):
            return "scratchpad patch is invalid: \(reason)"
        case .emptyPatch:
            return "scratchpad patch replacements must not be empty"
        case .emptyOldText(let replacementIndex):
            return "scratchpad patch replacement \(replacementIndex) oldText must not be empty"
        case .oldTextNotFound(let replacementIndex):
            return "scratchpad patch replacement \(replacementIndex) oldText was not found"
        case .oldTextNotUnique(let replacementIndex, _):
            return "scratchpad patch replacement \(replacementIndex) oldText must occur exactly once; found multiple matches"
        case .staleRevision(let expectedRevision, let currentRevision):
            return "expectedRevision \(expectedRevision) is stale; current revision is \(currentRevision)"
        case .missingDocument(let documentID):
            return "scratchpad document is missing: \(documentID.uuidString)"
        }
    }
}

final class ScratchpadDocumentStore {
    static let defaultMaxContentBytes = 1_048_576
    static let defaultMaxPatchBytes = 262_144

    let directoryURL: URL
    let maxContentBytes: Int
    let maxPatchBytes: Int

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    convenience init(
        runtimePaths: ToasttyRuntimePaths = .resolve(),
        fileManager: FileManager = .default,
        maxContentBytes: Int = ScratchpadDocumentStore.defaultMaxContentBytes,
        maxPatchBytes: Int = ScratchpadDocumentStore.defaultMaxPatchBytes
    ) {
        self.init(
            directoryURL: runtimePaths.scratchpadDocumentsDirectoryURL,
            fileManager: fileManager,
            maxContentBytes: maxContentBytes,
            maxPatchBytes: maxPatchBytes
        )
    }

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        maxContentBytes: Int = ScratchpadDocumentStore.defaultMaxContentBytes,
        maxPatchBytes: Int = ScratchpadDocumentStore.defaultMaxPatchBytes
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maxContentBytes = maxContentBytes
        self.maxPatchBytes = maxPatchBytes
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func documentURL(for documentID: UUID) -> URL {
        directoryURL.appending(path: "\(documentID.uuidString).json", directoryHint: .notDirectory)
    }

    func load(documentID: UUID) throws -> ScratchpadDocument? {
        try lock.withLock {
            try loadUnlocked(documentID: documentID)
        }
    }

    func createDocument(
        title: String?,
        content: String,
        sessionLink: ScratchpadSessionLink?,
        now: Date = Date()
    ) throws -> ScratchpadDocument {
        try createDocument(
            documentID: UUID(),
            title: title,
            content: content,
            sessionLink: sessionLink,
            now: now
        )
    }

    func createDocument(
        documentID: UUID,
        title: String?,
        content: String,
        sessionLink: ScratchpadSessionLink?,
        now: Date = Date()
    ) throws -> ScratchpadDocument {
        try lock.withLock {
            try validateContent(content)
            let document = ScratchpadDocument(
                documentID: documentID,
                revision: 1,
                title: WebPanelState.normalizedTitle(title),
                contentType: .html,
                content: content,
                createdAt: now,
                updatedAt: now,
                sessionLink: sessionLink
            )
            try writeUnlocked(document)
            return document
        }
    }

    func replaceContent(
        documentID: UUID,
        title: String?,
        content: String,
        expectedRevision: Int?,
        sessionLink: ScratchpadSessionLink?,
        now: Date = Date()
    ) throws -> ScratchpadDocument {
        try lock.withLock {
            try validateContent(content)
            guard var document = try loadUnlocked(documentID: documentID) else {
                throw ScratchpadDocumentStoreError.missingDocument(documentID)
            }

            if let expectedRevision,
               expectedRevision != document.revision {
                throw ScratchpadDocumentStoreError.staleRevision(
                    expectedRevision: expectedRevision,
                    currentRevision: document.revision
                )
            }

            document.revision += 1
            if let normalizedTitle = WebPanelState.normalizedTitle(title) {
                document.title = normalizedTitle
            }
            document.contentType = .html
            document.content = content
            document.updatedAt = now
            document.sessionLink = sessionLink ?? document.sessionLink
            try writeUnlocked(document)
            return document
        }
    }

    func applyPatch(
        documentID: UUID,
        patchJSON: String,
        expectedRevision: Int,
        sessionLink: ScratchpadSessionLink?,
        now: Date = Date()
    ) throws -> ScratchpadDocumentPatchOutcome {
        let patch = try decodePatchJSON(patchJSON)
        return try lock.withLock {
            guard var document = try loadUnlocked(documentID: documentID) else {
                throw ScratchpadDocumentStoreError.missingDocument(documentID)
            }

            guard expectedRevision == document.revision else {
                throw ScratchpadDocumentStoreError.staleRevision(
                    expectedRevision: expectedRevision,
                    currentRevision: document.revision
                )
            }

            let previousRevision = document.revision
            let patchedContent = try applyPatch(patch, to: document.content)
            try validateContent(patchedContent)

            document.revision += 1
            document.content = patchedContent
            document.updatedAt = now
            document.sessionLink = sessionLink ?? document.sessionLink
            try writeUnlocked(document)

            return ScratchpadDocumentPatchOutcome(
                document: document,
                documentID: document.documentID,
                previousRevision: previousRevision,
                revision: document.revision,
                appliedEditCount: patch.replacements.count
            )
        }
    }

    func updateSessionLink(
        documentID: UUID,
        sessionLink: ScratchpadSessionLink?,
        now: Date = Date()
    ) throws -> ScratchpadDocument {
        try lock.withLock {
            guard var document = try loadUnlocked(documentID: documentID) else {
                throw ScratchpadDocumentStoreError.missingDocument(documentID)
            }

            document.sessionLink = sessionLink
            document.updatedAt = now
            try writeUnlocked(document)
            return document
        }
    }

    private func validateContent(_ content: String) throws {
        let byteCount = content.utf8.count
        guard byteCount <= maxContentBytes else {
            throw ScratchpadDocumentStoreError.contentTooLarge(
                maxBytes: maxContentBytes,
                actualBytes: byteCount
            )
        }
    }

    private func decodePatchJSON(_ patchJSON: String) throws -> ScratchpadContentPatch {
        let byteCount = patchJSON.utf8.count
        guard byteCount <= maxPatchBytes else {
            throw ScratchpadDocumentStoreError.patchTooLarge(
                maxBytes: maxPatchBytes,
                actualBytes: byteCount
            )
        }

        guard let data = patchJSON.data(using: .utf8) else {
            throw ScratchpadDocumentStoreError.invalidPatch("patch must be valid UTF-8")
        }

        do {
            let patch = try decoder.decode(ScratchpadContentPatch.self, from: data)
            guard patch.replacements.isEmpty == false else {
                throw ScratchpadDocumentStoreError.emptyPatch
            }
            return patch
        } catch let error as ScratchpadDocumentStoreError {
            throw error
        } catch let error as DecodingError {
            throw ScratchpadDocumentStoreError.invalidPatch(Self.describe(decodingError: error))
        } catch {
            throw ScratchpadDocumentStoreError.invalidPatch("patch must be JSON with a non-empty replacements array of objects containing oldText and newText")
        }
    }

    private static func describe(decodingError error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .dataCorrupted(let ctx),
             .keyNotFound(_, let ctx),
             .typeMismatch(_, let ctx),
             .valueNotFound(_, let ctx):
            context = ctx
        @unknown default:
            return error.localizedDescription
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(context.debugDescription) (at \(path))"
    }

    private func applyPatch(_ patch: ScratchpadContentPatch, to content: String) throws -> String {
        var patchedContent = content
        for (index, replacement) in patch.replacements.enumerated() {
            let replacementIndex = index + 1
            guard replacement.oldText.isEmpty == false else {
                throw ScratchpadDocumentStoreError.emptyOldText(replacementIndex: replacementIndex)
            }

            let matchCount = occurrenceCount(of: replacement.oldText, in: patchedContent, maximum: 2)
            guard matchCount > 0 else {
                throw ScratchpadDocumentStoreError.oldTextNotFound(replacementIndex: replacementIndex)
            }
            guard matchCount == 1 else {
                throw ScratchpadDocumentStoreError.oldTextNotUnique(
                    replacementIndex: replacementIndex,
                    matchCount: matchCount
                )
            }

            guard let range = patchedContent.range(of: replacement.oldText, options: [.literal]) else {
                throw ScratchpadDocumentStoreError.oldTextNotFound(replacementIndex: replacementIndex)
            }
            patchedContent.replaceSubrange(range, with: replacement.newText)
        }
        return patchedContent
    }

    private func occurrenceCount(of needle: String, in haystack: String, maximum: Int) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [.literal], range: searchRange) {
            count += 1
            if count >= maximum {
                return count
            }
            searchRange = haystack.index(after: range.lowerBound)..<haystack.endIndex
        }
        return count
    }

    private func loadUnlocked(documentID: UUID) throws -> ScratchpadDocument? {
        let url = documentURL(for: documentID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(ScratchpadDocument.self, from: data)
    }

    private func writeUnlocked(_ document: ScratchpadDocument) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(document)
        try data.write(to: documentURL(for: document.documentID), options: [.atomic])
    }
}

extension ScratchpadDocumentStore: @unchecked Sendable {}

private enum ScratchpadPatchStrictDecoding {
    static func rejectUnknownKeys(decoder: Decoder, allowedKeys: Set<String>) throws {
        let container = try decoder.container(keyedBy: ScratchpadPatchDynamicCodingKey.self)
        let unknownKeys = container.allKeys
            .map(\.stringValue)
            .filter { allowedKeys.contains($0) == false }
            .sorted()
        guard unknownKeys.isEmpty else {
            let keyList = unknownKeys.joined(separator: ", ")
            throw DecodingError.dataCorruptedError(
                forKey: ScratchpadPatchDynamicCodingKey(stringValue: unknownKeys[0]),
                in: container,
                debugDescription: "unknown field(s): \(keyList)"
            )
        }
    }
}

private struct ScratchpadPatchDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
