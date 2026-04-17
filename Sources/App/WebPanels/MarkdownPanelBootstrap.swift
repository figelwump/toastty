import Foundation

enum MarkdownPanelTheme: String, Codable, Equatable, Sendable {
    case light
    case dark
}

struct MarkdownPanelBootstrap: Codable, Equatable, Sendable {
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
    let theme: MarkdownPanelTheme
    let textScale: Double

    init(
        contractVersion: Int = 4,
        filePath: String?,
        displayName: String,
        content: String,
        contentRevision: Int,
        isEditing: Bool = false,
        isDirty: Bool = false,
        hasExternalConflict: Bool = false,
        isSaving: Bool = false,
        saveErrorMessage: String? = nil,
        theme: MarkdownPanelTheme,
        textScale: Double
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
        self.textScale = textScale
    }
}

extension MarkdownPanelBootstrap {
    func setting(theme: MarkdownPanelTheme) -> Self {
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
            theme: theme,
            textScale: textScale
        )
    }

    func setting(textScale: Double) -> Self {
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
            theme: theme,
            textScale: textScale
        )
    }
}
