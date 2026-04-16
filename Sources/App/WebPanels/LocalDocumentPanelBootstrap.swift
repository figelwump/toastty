import Foundation

enum LocalDocumentPanelTheme: String, Codable, Equatable, Sendable {
    case light
    case dark
}

struct LocalDocumentPanelBootstrap: Codable, Equatable, Sendable {
    let contractVersion: Int
    let filePath: String?
    let displayName: String
    let content: String
    let contentRevision: Int
    let isEditing: Bool
    let isDirty: Bool
    let hasExternalConflict: Bool
    let isSaving: Bool
    let saveErrorMessage: String?
    let theme: LocalDocumentPanelTheme

    init(
        contractVersion: Int = 3,
        filePath: String?,
        displayName: String,
        content: String,
        contentRevision: Int,
        isEditing: Bool = false,
        isDirty: Bool = false,
        hasExternalConflict: Bool = false,
        isSaving: Bool = false,
        saveErrorMessage: String? = nil,
        theme: LocalDocumentPanelTheme
    ) {
        self.contractVersion = contractVersion
        self.filePath = filePath
        self.displayName = displayName
        self.content = content
        self.contentRevision = contentRevision
        self.isEditing = isEditing
        self.isDirty = isDirty
        self.hasExternalConflict = hasExternalConflict
        self.isSaving = isSaving
        self.saveErrorMessage = saveErrorMessage
        self.theme = theme
    }
}

extension LocalDocumentPanelBootstrap {
    func setting(theme: LocalDocumentPanelTheme) -> Self {
        Self(
            contractVersion: contractVersion,
            filePath: filePath,
            displayName: displayName,
            content: content,
            contentRevision: contentRevision,
            isEditing: isEditing,
            isDirty: isDirty,
            hasExternalConflict: hasExternalConflict,
            isSaving: isSaving,
            saveErrorMessage: saveErrorMessage,
            theme: theme
        )
    }
}
