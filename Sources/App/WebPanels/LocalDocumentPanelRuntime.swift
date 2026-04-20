import AppKit
import CoreState
import Foundation
import WebKit

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
    let currentAssetPath: String?
    let currentBootstrap: LocalDocumentPanelBootstrap?
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

@MainActor
final class LocalDocumentPanelRuntime: NSObject, ObservableObject, PanelHostLifecycleControlling {
    typealias DocumentLoader = @Sendable (WebPanelState) async -> LocalDocumentPanelDocumentSnapshot
    typealias DocumentSaver = @Sendable (String, String) async throws -> Void
    typealias SavedDocumentReader = @Sendable (String, String, LocalDocumentFormat) async throws -> LocalDocumentPanelDocumentSnapshot
    private static let scriptMessageHandlerName = "toasttyLocalDocumentPanel"
    nonisolated private static let syntaxHighlightThresholdBytes = 524_288

    private let panelID: UUID
    private let metadataDidChange: @MainActor (UUID, String?, String?) -> Void
    private let webView: FocusAwareWKWebView
    private let entryURL: URL?
    private let assetDirectoryURL: URL?
    private let documentLoader: DocumentLoader
    private let documentSaver: DocumentSaver
    private let savedDocumentReader: SavedDocumentReader
    private let reloadDebounceNanoseconds: UInt64
    private weak var activeSourceContainer: NSView?
    private var activeAttachment: PanelHostAttachmentToken?
    private var pendingDetachAttachment: PanelHostAttachmentToken?
    private var pendingDetachTask: Task<Void, Never>?
    private var currentWebState: WebPanelState?
    private var fileObserver: FilePathObserver?
    private var reloadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var activeSaveOperationID: UUID?
    private var reloadGeneration: UInt64 = 0
    private var pendingBootstrapScript: String?
    private var currentAssetURL: URL?
    private var currentBootstrap: LocalDocumentPanelBootstrap?
    private var session: LocalDocumentEditingSession?
    private var currentTheme: LocalDocumentPanelTheme = .dark
    private var currentTextScale: Double = AppState.defaultMarkdownTextScale

    init(
        panelID: UUID,
        metadataDidChange: @escaping @MainActor (UUID, String?, String?) -> Void,
        interactionDidRequestFocus: @escaping @MainActor (UUID) -> Void,
        bundle: Bundle = .main,
        entryURL: URL? = nil,
        documentLoader: @escaping DocumentLoader = { await LocalDocumentPanelRuntime.loadDocument(for: $0) },
        documentSaver: @escaping DocumentSaver = { try await LocalDocumentPanelRuntime.writeLocalDocument(at: $0, content: $1) },
        savedDocumentReader: @escaping SavedDocumentReader = { try await LocalDocumentPanelRuntime.readLocalDocument(at: $0, displayName: $1, format: $2) },
        reloadDebounceNanoseconds: UInt64 = 150_000_000
    ) {
        self.panelID = panelID
        self.metadataDidChange = metadataDidChange
        self.entryURL = entryURL ?? LocalDocumentPanelAssetLocator.entryURL(bundle: bundle)
        self.assetDirectoryURL = (entryURL ?? LocalDocumentPanelAssetLocator.entryURL(bundle: bundle))?.deletingLastPathComponent()
        self.documentLoader = documentLoader
        self.documentSaver = documentSaver
        self.savedDocumentReader = savedDocumentReader
        self.reloadDebounceNanoseconds = reloadDebounceNanoseconds

        let configuration = Self.makeWebViewConfiguration(
            for: WebPanelDefinition.localDocument.capabilityProfile
        )
        let webView = FocusAwareWKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView

        super.init()

        webView.interactionDidRequestFocus = { [panelID] in
            interactionDidRequestFocus(panelID)
        }
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: Self.scriptMessageHandlerName)
    }

    deinit {
        pendingDetachTask?.cancel()
        reloadTask?.cancel()
        saveTask?.cancel()
        let webView = webView
        Task { @MainActor in
            webView.interactionDidRequestFocus = nil
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.scriptMessageHandlerName)
            webView.removeFromSuperview()
        }
    }

    var lifecycleState: PanelHostLifecycleState {
        guard let activeAttachment else {
            return .detached
        }
        let sourceContainer = activeSourceContainer
        let attachedToContainer = sourceContainer != nil && webView.superview === sourceContainer
        let attachedToWindow = webView.window != nil && sourceContainer?.window != nil
        if pendingDetachAttachment == activeAttachment {
            return .attached(activeAttachment)
        }
        return attachedToContainer && attachedToWindow ? .ready(activeAttachment) : .attached(activeAttachment)
    }

    func automationState() -> LocalDocumentPanelRuntimeAutomationState {
        LocalDocumentPanelRuntimeAutomationState(
            lifecycleState: lifecycleState,
            currentTheme: currentTheme,
            hasPendingBootstrapScript: pendingBootstrapScript != nil,
            currentAssetPath: currentAssetURL?.path,
            currentBootstrap: currentBootstrap
        )
    }

    func canSaveFromCommand() -> Bool {
        session?.canSaveFromCommand == true
    }

    @discardableResult
    func saveFromCommand() -> Bool {
        guard let session else { return false }
        guard session.canSaveFromCommand else {
            return false
        }
        save(baseContentRevision: session.contentRevision)
        return true
    }

    @discardableResult
    func canCancelEditFromCommand() -> Bool {
        guard let session else { return false }
        return session.isEditing && session.isSaving == false
    }

    @discardableResult
    func cancelEditFromCommand() -> Bool {
        guard let session else { return false }
        guard session.isEditing, session.isSaving == false else {
            return false
        }
        cancelEditMode(baseContentRevision: session.contentRevision)
        return true
    }

    func closeConfirmationState() -> LocalDocumentCloseConfirmationState? {
        session?.closeConfirmationState
    }

    func enterEditMode() {
        guard var session else { return }
        guard session.beginEditing() else { return }
        objectWillChange.send()
        self.session = session
        updateCurrentBootstrap()
        pushPendingBootstrapIfPossible()
    }

    func updateDraftContent(_ content: String, baseContentRevision: Int) {
        guard var session else { return }
        guard session.updateDraft(content, baseContentRevision: baseContentRevision) else {
            return
        }
        self.session = session
        // Keep runtime inspection current without forcing a full bootstrap round-trip on each debounce tick.
        updateCurrentBootstrap()
    }

    func cancelEditMode(baseContentRevision: Int) {
        guard var session else { return }
        guard session.cancelEditing(baseContentRevision: baseContentRevision) else { return }
        objectWillChange.send()
        self.session = session
        updateCurrentBootstrap()
        pushPendingBootstrapIfPossible()
    }

    func save(baseContentRevision: Int) {
        startSave(baseContentRevision: baseContentRevision, allowConflictOverwrite: false)
    }

    func overwriteAfterConflict(baseContentRevision: Int) {
        startSave(baseContentRevision: baseContentRevision, allowConflictOverwrite: true)
    }

    func attachHost(to container: NSView, attachment: PanelHostAttachmentToken) {
        if let activeAttachment, attachment.generation < activeAttachment.generation {
            return
        }

        pendingDetachTask?.cancel()
        pendingDetachTask = nil
        pendingDetachAttachment = nil
        activeAttachment = attachment
        activeSourceContainer = container
        applyEffectiveAppearance(container.effectiveAppearance)

        guard webView.superview !== container else { return }
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func detachHost(attachment: PanelHostAttachmentToken) {
        guard let activeAttachment else { return }
        guard attachment == activeAttachment else { return }

        pendingDetachTask?.cancel()
        pendingDetachAttachment = attachment
        pendingDetachTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.pendingDetachAttachment == attachment,
                  self.activeAttachment == attachment else {
                return
            }
            self.pendingDetachTask = nil
            self.pendingDetachAttachment = nil
            self.activeAttachment = nil
            self.activeSourceContainer = nil
            self.webView.removeFromSuperview()
        }
    }

    func apply(webState: WebPanelState) {
        precondition(
            webState.definition == .localDocument,
            "LocalDocumentPanelRuntime cannot host \(webState.definition.rawValue) panels."
        )
        let didChangeState = currentWebState != webState
        currentWebState = webState
        synchronizeFileObservation(with: webState.filePath)

        guard didChangeState else { return }
        requestReload(debounced: false)
    }

    func setEffectivelyVisible(_ visible: Bool) {
        let shouldHideWebView = !visible
        guard webView.isHidden != shouldHideWebView else {
            return
        }

        // SwiftUI keeps hidden tabs/workspaces mounted with opacity, which
        // leaves the WKWebView alive in the AppKit hierarchy. Use isHidden so
        // AppKit stops treating that subtree as a cursor owner.
        webView.isHidden = shouldHideWebView
    }

    func applyTextScale(_ scale: Double) {
        let nextScale = AppState.clampedMarkdownTextScale(scale)
        guard abs(nextScale - currentTextScale) >= AppState.markdownTextScaleComparisonEpsilon else {
            return
        }

        currentTextScale = nextScale
        if let currentBootstrap {
            self.currentBootstrap = currentBootstrap.setting(textScale: nextScale)
        }
        pushTextScaleUpdateIfPossible()
    }

    func applyEffectiveAppearance(_ appearance: NSAppearance?) {
        // Re-assigning the same appearance still invalidates WKWebView cursor
        // rects, which can briefly reset the cursor to AppKit's default arrow
        // before WebKit reasserts its hovered cursor on the next mouse move.
        if Self.shouldApplyWebViewAppearance(current: webView.appearance, next: appearance) {
            webView.appearance = appearance
        }

        let nextTheme = Self.theme(for: appearance)
        guard nextTheme != currentTheme else { return }
        currentTheme = nextTheme
        pushThemeUpdateIfPossible()
    }

    nonisolated static func theme(for appearance: NSAppearance?) -> LocalDocumentPanelTheme {
        switch appearance?.bestMatch(from: [.darkAqua, .aqua]) {
        case .aqua:
            return .light
        case .darkAqua, nil:
            return .dark
        default:
            return .dark
        }
    }

    nonisolated static func shouldApplyWebViewAppearance(
        current: NSAppearance?,
        next: NSAppearance?
    ) -> Bool {
        current?.name != next?.name
    }

    nonisolated static func bootstrap(
        for webState: WebPanelState,
        theme: LocalDocumentPanelTheme = .dark,
        textScale: Double = AppState.defaultMarkdownTextScale
    ) async -> LocalDocumentPanelBootstrap {
        let document = await loadDocument(for: webState)
        let session = LocalDocumentEditingSession(document: document)
        return makeBootstrap(from: session, theme: theme, textScale: textScale)
    }

    nonisolated static func loadDocument(for webState: WebPanelState) async -> LocalDocumentPanelDocumentSnapshot {
        precondition(
            webState.definition == .localDocument,
            "LocalDocumentPanelRuntime cannot host \(webState.definition.rawValue) panels."
        )
        let format = resolvedFormat(for: webState)
        let normalizedFilePath = WebPanelState.normalizedFilePath(webState.filePath)
        let displayName = resolvedDisplayName(for: webState, filePath: normalizedFilePath ?? "")

        guard let normalizedFilePath else {
            return LocalDocumentPanelDocumentSnapshot(
                filePath: nil,
                displayName: displayName,
                format: format,
                content: missingFileDocument(
                    format: format,
                    filePath: nil,
                    message: "Toastty could not determine which local document this panel should render."
                ),
                diskRevision: nil
            )
        }

        return await loadDocumentSnapshot(
            at: normalizedFilePath,
            displayName: displayName,
            format: format
        )
    }

    nonisolated static func bootstrapJavaScript(for bootstrap: LocalDocumentPanelBootstrap) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(bootstrap),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "window.ToasttyLocalDocumentPanel?.receiveBootstrap(\(json));"
    }

    nonisolated static func textScaleJavaScript(for textScale: Double) -> String {
        "window.ToasttyLocalDocumentPanel?.setTextScale(\(String(format: "%.4f", textScale)));"
    }

    static func makeWebViewConfiguration(
        for capabilityProfile: WebPanelCapabilityProfile
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        if capabilityProfile == .localOnly {
            configuration.websiteDataStore = .nonPersistent()
        }
        return configuration
    }

    nonisolated static func makeBootstrap(
        from session: LocalDocumentEditingSession,
        theme: LocalDocumentPanelTheme,
        textScale: Double
    ) -> LocalDocumentPanelBootstrap {
        LocalDocumentPanelBootstrap(
            filePath: session.filePath,
            displayName: session.displayName,
            format: session.format,
            shouldHighlight: shouldHighlight(
                format: session.format,
                content: session.visibleContent,
                diskRevision: session.diskRevision
            ),
            content: session.visibleContent,
            contentRevision: session.contentRevision,
            isEditing: session.isEditing,
            isDirty: session.isDirty,
            hasExternalConflict: session.hasExternalConflict,
            isSaving: session.isSaving,
            saveErrorMessage: session.saveErrorMessage,
            theme: theme,
            textScale: textScale
        )
    }
}

private extension LocalDocumentPanelRuntime {
    enum BridgeEvent {
        case enterEdit
        case draftDidChange(content: String, baseContentRevision: Int)
        case save(baseContentRevision: Int)
        case cancelEdit(baseContentRevision: Int)
        case overwriteAfterConflict(baseContentRevision: Int)

        init?(messageBody: Any) {
            guard let body = messageBody as? [String: Any],
                  let type = body["type"] as? String else {
                return nil
            }

            switch type {
            case "enterEdit":
                self = .enterEdit
            case "draftDidChange":
                guard let content = body["content"] as? String,
                      let baseContentRevision = body["baseContentRevision"] as? Int else {
                    return nil
                }
                self = .draftDidChange(content: content, baseContentRevision: baseContentRevision)
            case "save":
                guard let baseContentRevision = body["baseContentRevision"] as? Int else {
                    return nil
                }
                self = .save(baseContentRevision: baseContentRevision)
            case "cancelEdit":
                guard let baseContentRevision = body["baseContentRevision"] as? Int else {
                    return nil
                }
                self = .cancelEdit(baseContentRevision: baseContentRevision)
            case "overwriteAfterConflict":
                guard let baseContentRevision = body["baseContentRevision"] as? Int else {
                    return nil
                }
                self = .overwriteAfterConflict(baseContentRevision: baseContentRevision)
            default:
                return nil
            }
        }
    }

    func handleBridgeEvent(_ event: BridgeEvent) {
        switch event {
        case .enterEdit:
            enterEditMode()
        case .draftDidChange(let content, let baseContentRevision):
            updateDraftContent(content, baseContentRevision: baseContentRevision)
        case .save(let baseContentRevision):
            save(baseContentRevision: baseContentRevision)
        case .cancelEdit(let baseContentRevision):
            cancelEditMode(baseContentRevision: baseContentRevision)
        case .overwriteAfterConflict(let baseContentRevision):
            overwriteAfterConflict(baseContentRevision: baseContentRevision)
        }
    }

    func synchronizeFileObservation(with filePath: String?) {
        guard let normalizedFilePath = WebPanelState.normalizedFilePath(filePath) else {
            fileObserver?.invalidate()
            fileObserver = nil
            return
        }

        if let fileObserver {
            fileObserver.update(path: normalizedFilePath)
            return
        }

        fileObserver = FilePathObserver(path: normalizedFilePath) { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestReload(debounced: true)
            }
        }
    }

    func requestReload(debounced: Bool) {
        guard let webState = currentWebState else { return }

        reloadGeneration &+= 1
        let generation = reloadGeneration
        let documentLoader = documentLoader
        let reloadDelayNanoseconds = debounced ? reloadDebounceNanoseconds : 0

        reloadTask?.cancel()
        pendingBootstrapScript = nil

        reloadTask = Task { [weak self] in
            if reloadDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: reloadDelayNanoseconds)
            }

            let document = await documentLoader(webState)
            guard let self else { return }
            defer {
                if generation == self.reloadGeneration {
                    self.reloadTask = nil
                }
            }
            guard Task.isCancelled == false, generation == self.reloadGeneration else {
                return
            }

            if var existingSession = self.session {
                let didReplaceLoadedContent = existingSession.filePath != document.filePath ||
                    existingSession.loadedContent != document.content

                if existingSession.isSaving {
                    return
                }

                if existingSession.isEditing && existingSession.isDirty && didReplaceLoadedContent {
                    existingSession.applyExternalConflict(with: document)
                } else {
                    existingSession.replaceCleanBaseline(with: document)
                }
                self.objectWillChange.send()
                self.session = existingSession
            } else {
                self.objectWillChange.send()
                self.session = LocalDocumentEditingSession(document: document)
            }

            self.updateCurrentBootstrap(emitMetadata: true)
            self.pushPendingBootstrapIfPossible()
        }
    }

    func startSave(baseContentRevision: Int, allowConflictOverwrite: Bool) {
        guard var session else { return }

        if allowConflictOverwrite == false,
           session.finishNoOpSave(baseContentRevision: baseContentRevision) {
            objectWillChange.send()
            self.session = session
            updateCurrentBootstrap()
            pushPendingBootstrapIfPossible()
            return
        }

        guard let request = session.beginSave(
            baseContentRevision: baseContentRevision,
            allowConflictOverwrite: allowConflictOverwrite
        ) else {
            return
        }

        let operationID = UUID()
        saveTask?.cancel()
        activeSaveOperationID = operationID
        objectWillChange.send()
        self.session = session
        updateCurrentBootstrap()
        pushPendingBootstrapIfPossible()

        let documentSaver = documentSaver
        let savedDocumentReader = savedDocumentReader
        saveTask = Task { [weak self] in
            do {
                try await documentSaver(request.filePath, request.content)
                let document = try await savedDocumentReader(
                    request.filePath,
                    request.displayName,
                    session.format
                )
                await MainActor.run { [weak self] in
                    self?.completeSave(
                        operationID: operationID,
                        request: request,
                        document: document
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.failSave(
                        operationID: operationID,
                        request: request,
                        error: error
                    )
                }
            }
        }
    }

    func completeSave(
        operationID: UUID,
        request: LocalDocumentSaveRequest,
        document: LocalDocumentPanelDocumentSnapshot
    ) {
        guard activeSaveOperationID == operationID,
              var session else {
            return
        }

        activeSaveOperationID = nil
        saveTask = nil
        guard session.settleSave(
            with: document,
            expectedContent: request.content,
            baseContentRevision: request.baseContentRevision
        ) else {
            return
        }

        objectWillChange.send()
        self.session = session
        updateCurrentBootstrap()
        pushPendingBootstrapIfPossible()
    }

    func failSave(
        operationID: UUID,
        request: LocalDocumentSaveRequest,
        error: Error
    ) {
        guard activeSaveOperationID == operationID,
              var session else {
            return
        }

        activeSaveOperationID = nil
        saveTask = nil
        guard session.failSave(
            message: error.localizedDescription,
            baseContentRevision: request.baseContentRevision
        ) else {
            return
        }

        objectWillChange.send()
        self.session = session
        updateCurrentBootstrap()
        pushPendingBootstrapIfPossible()
    }

    func ensurePanelAppLoaded() {
        guard let entryURL, let assetDirectoryURL else {
            let fallbackHTML = Self.fallbackHTML(
                title: "Local document assets unavailable",
                detail: "Toastty could not load the bundled local document panel resources."
            )
            webView.loadHTMLString(fallbackHTML, baseURL: nil)
            currentAssetURL = nil
            return
        }

        if currentAssetURL == entryURL {
            pushPendingBootstrapIfPossible()
            return
        }

        currentAssetURL = entryURL
        webView.loadFileURL(entryURL, allowingReadAccessTo: assetDirectoryURL)
    }

    func pushPendingBootstrapIfPossible() {
        guard let entryURL else {
            ensurePanelAppLoaded()
            return
        }

        if currentAssetURL != entryURL {
            ensurePanelAppLoaded()
            return
        }

        if pendingBootstrapScript == nil {
            stageCurrentBootstrapScript()
        }
        guard let pendingBootstrapScript else { return }
        webView.evaluateJavaScript(pendingBootstrapScript) { [weak self] _, error in
            guard let self else { return }
            if error == nil {
                self.pendingBootstrapScript = nil
            }
        }
    }

    func pushThemeUpdateIfPossible() {
        guard let session else { return }

        let themedBootstrap = Self.makeBootstrap(
            from: session,
            theme: currentTheme,
            textScale: currentTextScale
        )
        guard themedBootstrap != currentBootstrap else { return }

        pendingBootstrapScript = nil
        currentBootstrap = themedBootstrap
        pushPendingBootstrapIfPossible()
    }

    func updateCurrentBootstrap(emitMetadata: Bool = false) {
        guard let session else { return }
        let bootstrap = Self.makeBootstrap(
            from: session,
            theme: currentTheme,
            textScale: currentTextScale
        )
        currentBootstrap = bootstrap
        pendingBootstrapScript = nil
        if emitMetadata {
            metadataDidChange(panelID, bootstrap.displayName, nil)
        }
    }

    func pushTextScaleUpdateIfPossible() {
        guard currentBootstrap != nil else { return }
        guard let entryURL else {
            ensurePanelAppLoaded()
            return
        }

        if currentAssetURL != entryURL {
            ensurePanelAppLoaded()
            return
        }

        let script = Self.textScaleJavaScript(for: currentTextScale)
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self, error != nil else { return }
            self.pendingBootstrapScript = nil
            self.pushPendingBootstrapIfPossible()
        }
    }

    func stageCurrentBootstrapScript() {
        guard let currentBootstrap,
              let script = Self.bootstrapJavaScript(for: currentBootstrap) else {
            return
        }
        pendingBootstrapScript = script
    }

    nonisolated static func readLocalDocument(
        at filePath: String,
        displayName: String,
        format: LocalDocumentFormat
    ) async throws -> LocalDocumentPanelDocumentSnapshot {
        try await Task.detached(priority: .utility) {
            let fileURL = URL(fileURLWithPath: filePath)
            var encoding = String.Encoding.utf8
            let content = try String(contentsOf: fileURL, usedEncoding: &encoding)
            let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
            let diskRevision = LocalDocumentPanelDiskRevision(
                fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                modificationDate: attributes[.modificationDate] as? Date,
                size: (attributes[.size] as? NSNumber)?.uint64Value
            )
            return LocalDocumentPanelDocumentSnapshot(
                filePath: filePath,
                displayName: displayName,
                format: format,
                content: content,
                diskRevision: diskRevision
            )
        }.value
    }

    nonisolated static func loadDocumentSnapshot(
        at filePath: String,
        displayName: String,
        format: LocalDocumentFormat
    ) async -> LocalDocumentPanelDocumentSnapshot {
        do {
            return try await readLocalDocument(
                at: filePath,
                displayName: displayName,
                format: format
            )
        } catch {
            return LocalDocumentPanelDocumentSnapshot(
                filePath: filePath,
                displayName: displayName,
                format: format,
                content: missingFileDocument(
                    format: format,
                    filePath: filePath,
                    message: error.localizedDescription
                ),
                diskRevision: nil
            )
        }
    }

    nonisolated static func writeLocalDocument(at filePath: String, content: String) async throws {
        try await Task.detached(priority: .utility) {
            let fileURL = URL(fileURLWithPath: filePath)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }.value
    }

    nonisolated static func resolvedDisplayName(for webState: WebPanelState, filePath: String) -> String {
        if webState.title.isEmpty == false,
           webState.title != webState.definition.defaultTitle {
            return webState.title
        }

        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
        return fileName.isEmpty ? webState.definition.defaultTitle : fileName
    }

    nonisolated static func resolvedFormat(for webState: WebPanelState) -> LocalDocumentFormat {
        webState.localDocument?.format ?? .markdown
    }

    nonisolated static func shouldHighlight(
        format _: LocalDocumentFormat,
        content: String,
        diskRevision: LocalDocumentPanelDiskRevision?
    ) -> Bool {
        // Experiment: markdown is rendered as code, so it now follows the same
        // size threshold as yaml/toml instead of always highlighting.
        guard diskRevision != nil else {
            return false
        }
        return content.utf8.count <= syntaxHighlightThresholdBytes
    }

    nonisolated static func missingFileDocument(
        format _: LocalDocumentFormat,
        filePath: String?,
        message: String
    ) -> String {
        codeMissingFileDocument(filePath: filePath, message: message)
    }

    nonisolated static func codeMissingFileDocument(filePath: String?, message: String) -> String {
        var lines = [
            "Toastty could not load this document.",
        ]

        if let filePath, filePath.isEmpty == false {
            lines += [
                "",
                "Path:",
                filePath,
            ]
        }

        lines += [
            "",
            "Reason:",
            message,
        ]

        return lines.joined(separator: "\n")
    }

    nonisolated static func fallbackHTML(title: String, detail: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title)</title>
          <style>
            body {
              margin: 0;
              min-height: 100vh;
              display: flex;
              align-items: center;
              justify-content: center;
              background: #f8f4ee;
              color: #25180f;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            }
            main {
              max-width: 32rem;
              padding: 1.5rem;
              border: 1px solid rgba(90, 53, 25, 0.12);
              border-radius: 18px;
              background: rgba(255, 251, 246, 0.95);
            }
            p { line-height: 1.6; color: #6f533a; }
          </style>
        </head>
        <body>
          <main>
            <h1>\(title)</h1>
            <p>\(detail)</p>
          </main>
        </body>
        </html>
        """
    }
}

extension LocalDocumentPanelRuntime: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushPendingBootstrapIfPossible()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let requestURL = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if requestURL.isFileURL == false {
            decisionHandler(.cancel)
            return
        }

        guard let currentAssetURL else {
            decisionHandler(.allow)
            return
        }

        let requestedPath = requestURL.standardizedFileURL.path
        let currentPath = currentAssetURL.standardizedFileURL.path
        decisionHandler(requestedPath == currentPath ? .allow : .cancel)
    }
}

extension LocalDocumentPanelRuntime: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.scriptMessageHandlerName,
              let event = BridgeEvent(messageBody: message.body) else {
            return
        }

        handleBridgeEvent(event)
    }
}
