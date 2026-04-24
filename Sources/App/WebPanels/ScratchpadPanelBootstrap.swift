import Foundation

enum ScratchpadPanelTheme: String, Codable, Equatable, Sendable {
    case light
    case dark
}

struct ScratchpadPanelBootstrap: Codable, Equatable, Sendable {
    let contractVersion: Int
    let documentID: UUID?
    let displayName: String
    let revision: Int?
    let contentHTML: String?
    let missingDocument: Bool
    let message: String?
    let theme: ScratchpadPanelTheme

    init(
        contractVersion: Int = 1,
        documentID: UUID?,
        displayName: String,
        revision: Int?,
        contentHTML: String?,
        missingDocument: Bool = false,
        message: String? = nil,
        theme: ScratchpadPanelTheme
    ) {
        self.contractVersion = contractVersion
        self.documentID = documentID
        self.displayName = displayName
        self.revision = revision
        self.contentHTML = contentHTML
        self.missingDocument = missingDocument
        self.message = message
        self.theme = theme
    }
}

extension ScratchpadPanelBootstrap {
    func setting(theme: ScratchpadPanelTheme) -> Self {
        Self(
            contractVersion: contractVersion,
            documentID: documentID,
            displayName: displayName,
            revision: revision,
            contentHTML: contentHTML,
            missingDocument: missingDocument,
            message: message,
            theme: theme
        )
    }
}
