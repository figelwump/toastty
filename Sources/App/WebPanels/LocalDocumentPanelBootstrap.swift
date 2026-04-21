import CoreState
import Foundation

enum LocalDocumentPanelTheme: String, Codable, Equatable, Sendable {
    case light
    case dark
}

enum LocalDocumentHighlightState: String, Codable, Equatable, Sendable {
    case enabled
    case disabledForLargeFile
    case unsupportedFormat
    case unavailable
}

struct LocalDocumentPanelBootstrap: Codable, Equatable, Sendable {
    let contractVersion: Int
    let filePath: String?
    let displayName: String
    let format: LocalDocumentFormat
    let syntaxLanguage: LocalDocumentSyntaxLanguage?
    let formatLabel: String
    let shouldHighlight: Bool
    let highlightState: LocalDocumentHighlightState
    let content: String
    let contentRevision: Int
    let isEditing: Bool
    let isDirty: Bool
    let hasExternalConflict: Bool
    let isSaving: Bool
    let saveErrorMessage: String?
    let theme: LocalDocumentPanelTheme
    let textScale: Double

    init(
        contractVersion: Int = 6,
        filePath: String?,
        displayName: String,
        format: LocalDocumentFormat = .markdown,
        syntaxLanguage: LocalDocumentSyntaxLanguage? = nil,
        formatLabel: String? = nil,
        highlightState: LocalDocumentHighlightState = .enabled,
        shouldHighlight: Bool? = nil,
        content: String,
        contentRevision: Int,
        isEditing: Bool = false,
        isDirty: Bool = false,
        hasExternalConflict: Bool = false,
        isSaving: Bool = false,
        saveErrorMessage: String? = nil,
        theme: LocalDocumentPanelTheme,
        textScale: Double = AppState.defaultMarkdownTextScale
    ) {
        let classification = LocalDocumentClassifier.classification(
            format: format,
            filePath: filePath
        )
        self.contractVersion = contractVersion
        self.filePath = filePath
        self.displayName = displayName
        self.format = format
        self.syntaxLanguage = syntaxLanguage ?? classification.syntaxLanguage
        self.formatLabel = formatLabel ?? classification.formatLabel
        self.highlightState = highlightState
        self.shouldHighlight = shouldHighlight ?? (highlightState == .enabled)
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

extension LocalDocumentPanelBootstrap {
    func setting(theme: LocalDocumentPanelTheme) -> Self {
        Self(
            contractVersion: contractVersion,
            filePath: filePath,
            displayName: displayName,
            format: format,
            syntaxLanguage: syntaxLanguage,
            formatLabel: formatLabel,
            highlightState: highlightState,
            shouldHighlight: shouldHighlight,
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
            format: format,
            syntaxLanguage: syntaxLanguage,
            formatLabel: formatLabel,
            highlightState: highlightState,
            shouldHighlight: shouldHighlight,
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
