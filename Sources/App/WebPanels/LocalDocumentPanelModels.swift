import CoreState
import Foundation

enum LocalDocumentPanelAssetLocator {
    private static let directory = "WebPanels/local-document-panel"
    private static let fileName = "index"
    private static let fileExtension = "html"

    static func entryURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: fileName, withExtension: fileExtension, subdirectory: directory)
    }

    static func directoryURL(bundle: Bundle = .main) -> URL? {
        entryURL(bundle: bundle)?.deletingLastPathComponent()
    }
}

struct LocalDocumentPanelRuntimeAutomationState: Equatable, Sendable {
    let lifecycleState: PanelHostLifecycleState
    let currentTheme: LocalDocumentPanelTheme
    let hasPendingBootstrapScript: Bool
    let pendingRevealLine: Int?
    let currentAssetPath: String?
    let currentBootstrap: LocalDocumentPanelBootstrap?
    let searchState: LocalDocumentSearchState?
    let isSearchFieldFocused: Bool
}

struct LocalDocumentPanelDiskRevision: Equatable, Sendable {
    let fileNumber: UInt64?
    let modificationDate: Date?
    let size: UInt64?
}

struct LocalDocumentPanelDocumentSnapshot: Equatable, Sendable {
    let filePath: String?
    let displayName: String
    let format: LocalDocumentFormat
    let content: String
    let diskRevision: LocalDocumentPanelDiskRevision?

    init(
        filePath: String?,
        displayName: String,
        format: LocalDocumentFormat = .markdown,
        content: String,
        diskRevision: LocalDocumentPanelDiskRevision?
    ) {
        self.filePath = filePath
        self.displayName = displayName
        self.format = format
        self.content = content
        self.diskRevision = diskRevision
    }
}

struct LocalDocumentSaveRequest: Equatable, Sendable {
    let filePath: String
    let displayName: String
    let content: String
    let baseContentRevision: Int
}

enum LocalDocumentCloseConfirmationKind: Equatable, Sendable {
    case dirtyDraft
    case saveInProgress
}

struct LocalDocumentCloseConfirmationState: Equatable, Sendable {
    let kind: LocalDocumentCloseConfirmationKind
    let displayName: String
}

struct LocalDocumentEditingSession: Equatable, Sendable {
    var filePath: String?
    var displayName: String
    var format: LocalDocumentFormat
    var loadedContent: String
    var draftContent: String
    var contentRevision: Int
    var diskRevision: LocalDocumentPanelDiskRevision?
    var isEditing: Bool
    var hasExternalConflict: Bool
    var isSaving: Bool
    var saveErrorMessage: String?

    var isDirty: Bool {
        draftContent != loadedContent
    }

    var visibleContent: String {
        isEditing ? draftContent : loadedContent
    }

    var closeConfirmationState: LocalDocumentCloseConfirmationState? {
        guard isEditing else {
            return nil
        }
        if isSaving {
            return LocalDocumentCloseConfirmationState(
                kind: .saveInProgress,
                displayName: displayName
            )
        }
        guard isDirty else {
            return nil
        }
        return LocalDocumentCloseConfirmationState(
            kind: .dirtyDraft,
            displayName: displayName
        )
    }

    var canSaveFromCommand: Bool {
        filePath != nil &&
            isEditing &&
            isSaving == false &&
            hasExternalConflict == false
    }

    init(document: LocalDocumentPanelDocumentSnapshot) {
        filePath = document.filePath
        displayName = document.displayName
        format = document.format
        loadedContent = document.content
        draftContent = document.content
        contentRevision = 1
        diskRevision = document.diskRevision
        isEditing = false
        hasExternalConflict = false
        isSaving = false
        saveErrorMessage = nil
    }

    mutating func replaceCleanBaseline(with document: LocalDocumentPanelDocumentSnapshot) {
        let shouldAdvanceRevision = contentRevision == 0 ||
            filePath != document.filePath ||
            format != document.format ||
            loadedContent != document.content
        let shouldReplaceDraftContent = isEditing == false || isDirty == false

        filePath = document.filePath
        displayName = document.displayName
        format = document.format
        loadedContent = document.content
        diskRevision = document.diskRevision
        hasExternalConflict = false
        isSaving = false
        saveErrorMessage = nil

        if shouldReplaceDraftContent {
            draftContent = document.content
        }

        if shouldAdvanceRevision {
            contentRevision += 1
        }
    }

    mutating func beginEditing() -> Bool {
        guard filePath != nil, isEditing == false else {
            return false
        }

        draftContent = loadedContent
        isEditing = true
        saveErrorMessage = nil
        return true
    }

    mutating func updateDraft(_ content: String, baseContentRevision: Int) -> Bool {
        guard isEditing, isSaving == false, baseContentRevision == contentRevision else {
            return false
        }

        draftContent = content
        saveErrorMessage = nil
        return true
    }

    mutating func cancelEditing(baseContentRevision: Int) -> Bool {
        guard isEditing, baseContentRevision == contentRevision else {
            return false
        }

        draftContent = loadedContent
        isEditing = false
        hasExternalConflict = false
        isSaving = false
        saveErrorMessage = nil
        contentRevision += 1
        return true
    }

    mutating func beginSave(
        baseContentRevision: Int,
        allowConflictOverwrite: Bool
    ) -> LocalDocumentSaveRequest? {
        guard let filePath,
              isEditing,
              isSaving == false,
              baseContentRevision == contentRevision else {
            return nil
        }
        guard allowConflictOverwrite ? hasExternalConflict : hasExternalConflict == false else {
            return nil
        }

        saveErrorMessage = nil
        isSaving = true
        return LocalDocumentSaveRequest(
            filePath: filePath,
            displayName: displayName,
            content: draftContent,
            baseContentRevision: baseContentRevision
        )
    }

    mutating func finishNoOpSave(baseContentRevision: Int) -> Bool {
        guard isEditing,
              isDirty == false,
              hasExternalConflict == false,
              isSaving == false,
              baseContentRevision == contentRevision else {
            return false
        }

        isEditing = false
        saveErrorMessage = nil
        contentRevision += 1
        return true
    }

    mutating func settleSave(
        with document: LocalDocumentPanelDocumentSnapshot,
        expectedContent: String,
        baseContentRevision: Int
    ) -> Bool {
        guard isSaving, baseContentRevision == contentRevision else {
            return false
        }

        let savedContentMatchesDisk = document.content == expectedContent

        filePath = document.filePath
        displayName = document.displayName
        format = document.format
        loadedContent = document.content
        diskRevision = document.diskRevision
        isSaving = false
        saveErrorMessage = nil

        if savedContentMatchesDisk {
            draftContent = document.content
            isEditing = false
            hasExternalConflict = false
            contentRevision += 1
        } else {
            hasExternalConflict = true
        }

        return true
    }

    mutating func failSave(message: String, baseContentRevision: Int) -> Bool {
        guard isSaving, baseContentRevision == contentRevision else {
            return false
        }

        isSaving = false
        saveErrorMessage = message
        return true
    }

    mutating func applyExternalConflict(with document: LocalDocumentPanelDocumentSnapshot) {
        filePath = document.filePath
        displayName = document.displayName
        format = document.format
        loadedContent = document.content
        diskRevision = document.diskRevision
        hasExternalConflict = true
        isSaving = false
        saveErrorMessage = nil
    }
}

enum LocalDocumentSearchCommand: Equatable, Sendable {
    case setQuery(String)
    case findNext(String)
    case findPrevious(String)
    case clear

    var query: String? {
        switch self {
        case .setQuery(let query), .findNext(let query), .findPrevious(let query):
            query
        case .clear:
            nil
        }
    }
}
