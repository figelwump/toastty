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

enum ScratchpadDocumentStoreError: LocalizedError, Equatable {
    case contentTooLarge(maxBytes: Int, actualBytes: Int)
    case staleRevision(expectedRevision: Int, currentRevision: Int)
    case missingDocument(UUID)

    var errorDescription: String? {
        switch self {
        case .contentTooLarge(let maxBytes, let actualBytes):
            return "scratchpad content is too large (\(actualBytes) bytes, maximum \(maxBytes) bytes)"
        case .staleRevision(let expectedRevision, let currentRevision):
            return "expectedRevision \(expectedRevision) is stale; current revision is \(currentRevision)"
        case .missingDocument(let documentID):
            return "scratchpad document is missing: \(documentID.uuidString)"
        }
    }
}

final class ScratchpadDocumentStore {
    static let defaultMaxContentBytes = 1_048_576

    let directoryURL: URL
    let maxContentBytes: Int

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    convenience init(
        runtimePaths: ToasttyRuntimePaths = .resolve(),
        fileManager: FileManager = .default,
        maxContentBytes: Int = ScratchpadDocumentStore.defaultMaxContentBytes
    ) {
        self.init(
            directoryURL: runtimePaths.scratchpadDocumentsDirectoryURL,
            fileManager: fileManager,
            maxContentBytes: maxContentBytes
        )
    }

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        maxContentBytes: Int = ScratchpadDocumentStore.defaultMaxContentBytes
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maxContentBytes = maxContentBytes
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

    private func validateContent(_ content: String) throws {
        let byteCount = content.utf8.count
        guard byteCount <= maxContentBytes else {
            throw ScratchpadDocumentStoreError.contentTooLarge(
                maxBytes: maxContentBytes,
                actualBytes: byteCount
            )
        }
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
