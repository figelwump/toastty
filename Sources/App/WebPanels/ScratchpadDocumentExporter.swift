import CoreState
import Foundation

struct ScratchpadDocumentExportOutcome: Equatable, Sendable {
    let fileURL: URL
    let documentID: UUID
    let revision: Int
    let title: String?
}

enum ScratchpadDocumentExporter {
    static func exportToDefaultLocation(
        documentID: UUID,
        documentStore: ScratchpadDocumentStore,
        fileManager: FileManager = .default
    ) throws -> ScratchpadDocumentExportOutcome {
        try export(
            documentID: documentID,
            documentStore: documentStore,
            to: defaultExportURL(documentID: documentID, documentStore: documentStore),
            fileManager: fileManager
        )
    }

    static func export(
        documentID: UUID,
        documentStore: ScratchpadDocumentStore,
        to targetURL: URL,
        fileManager: FileManager = .default
    ) throws -> ScratchpadDocumentExportOutcome {
        guard let document = try documentStore.load(documentID: documentID) else {
            throw ScratchpadDocumentStoreError.missingDocument(documentID)
        }

        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try document.content.write(to: targetURL, atomically: true, encoding: .utf8)

        return ScratchpadDocumentExportOutcome(
            fileURL: targetURL,
            documentID: document.documentID,
            revision: document.revision,
            title: document.title
        )
    }

    static func defaultExportURL(
        documentID: UUID,
        documentStore: ScratchpadDocumentStore
    ) -> URL {
        documentStore.directoryURL
            .deletingLastPathComponent()
            .appending(path: "scratchpad-exports", directoryHint: .isDirectory)
            .appending(path: "\(documentID.uuidString).html", directoryHint: .notDirectory)
    }

    static func defaultFileName(title: String?, documentID: UUID) -> String {
        let fallback = "Scratchpad-\(String(documentID.uuidString.prefix(8)))"
        let basename = sanitizedFileBasename(title) ?? fallback
        return basename.hasSuffix(".html") ? basename : "\(basename).html"
    }

    private static func sanitizedFileBasename(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = trimmed.components(separatedBy: invalidCharacters)
        let sanitized = components
            .joined(separator: "-")
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        return sanitized.isEmpty ? nil : sanitized
    }
}
