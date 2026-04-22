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

@MainActor
final class LocalDocumentPanelRuntime: NSObject, ObservableObject, PanelHostLifecycleControlling {
    typealias DocumentLoader = @Sendable (WebPanelState) async -> LocalDocumentPanelDocumentSnapshot
    typealias DocumentSaver = @Sendable (String, String) async throws -> Void
    typealias SavedDocumentReader = @Sendable (String, String, LocalDocumentFormat) async throws -> LocalDocumentPanelDocumentSnapshot
    typealias ExternalFileOpener = @Sendable (URL) -> Bool
    typealias BridgeScriptCompletion = @MainActor @Sendable (Any?, Error?) -> Void
    typealias BridgeScriptEvaluator = @MainActor (String, @escaping BridgeScriptCompletion) -> Void
    typealias SearchExecutor = @MainActor (FocusAwareWKWebView, LocalDocumentSearchCommand, @escaping (Bool?) -> Void) -> Void
    typealias SearchSessionResetter = @MainActor (FocusAwareWKWebView) -> Void
    typealias DiagnosticLogger = @MainActor @Sendable (ToasttyLogLevel, String, [String: String]) -> Void
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
    private let externalFileOpener: ExternalFileOpener
    private let bridgeScriptEvaluator: BridgeScriptEvaluator
    private let searchExecutor: SearchExecutor
    private let searchSessionResetter: SearchSessionResetter
    private let diagnosticLogger: DiagnosticLogger
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
    private var pendingRevealLine: Int?
    private var currentAssetURL: URL?
    private var currentBootstrap: LocalDocumentPanelBootstrap?
    private var session: LocalDocumentEditingSession?
    private var currentTheme: LocalDocumentPanelTheme = .dark
    private var currentTextScale: Double = AppState.defaultMarkdownTextScale
    private var searchStateValue: LocalDocumentSearchState?
    private var searchFieldFocused = false
    private var activeSearchRequestGeneration: UInt64 = 0
    private var shouldRefreshSearchAfterBootstrap = false
    private var isPanelBridgeReady = false
    private var isSearchControllerReady = false

    init(
        panelID: UUID,
        metadataDidChange: @escaping @MainActor (UUID, String?, String?) -> Void,
        interactionDidRequestFocus: @escaping @MainActor (UUID) -> Void,
        bundle: Bundle = .main,
        entryURL: URL? = nil,
        documentLoader: @escaping DocumentLoader = { await LocalDocumentPanelRuntime.loadDocument(for: $0) },
        documentSaver: @escaping DocumentSaver = { try await LocalDocumentPanelRuntime.writeLocalDocument(at: $0, content: $1) },
        savedDocumentReader: @escaping SavedDocumentReader = { try await LocalDocumentPanelRuntime.readLocalDocument(at: $0, displayName: $1, format: $2) },
        externalFileOpener: @escaping ExternalFileOpener = { NSWorkspace.shared.open($0) },
        bridgeScriptEvaluator: BridgeScriptEvaluator? = nil,
        searchExecutor: @escaping SearchExecutor = { webView, command, completion in
            guard let script = LocalDocumentPanelRuntime.searchJavaScript(for: command) else {
                completion(nil)
                return
            }

            webView.evaluateJavaScript(script) { result, error in
                guard error == nil else {
                    completion(nil)
                    return
                }
                completion(LocalDocumentPanelRuntime.searchExecutionResult(from: result))
            }
        },
        searchSessionResetter: @escaping SearchSessionResetter = { webView in
            LocalDocumentPanelRuntime.resetSearchSession(in: webView)
        },
        diagnosticLogger: @escaping DiagnosticLogger = { level, message, metadata in
            switch level {
            case .debug:
                ToasttyLog.debug(message, category: .state, metadata: metadata)
            case .info:
                ToasttyLog.info(message, category: .state, metadata: metadata)
            case .warning:
                ToasttyLog.warning(message, category: .state, metadata: metadata)
            case .error:
                ToasttyLog.error(message, category: .state, metadata: metadata)
            }
        },
        reloadDebounceNanoseconds: UInt64 = 150_000_000
    ) {
        self.panelID = panelID
        self.metadataDidChange = metadataDidChange
        self.entryURL = entryURL ?? LocalDocumentPanelAssetLocator.entryURL(bundle: bundle)
        self.assetDirectoryURL = (entryURL ?? LocalDocumentPanelAssetLocator.entryURL(bundle: bundle))?.deletingLastPathComponent()
        self.documentLoader = documentLoader
        self.documentSaver = documentSaver
        self.savedDocumentReader = savedDocumentReader
        self.externalFileOpener = externalFileOpener
        self.searchExecutor = searchExecutor
        self.searchSessionResetter = searchSessionResetter
        self.diagnosticLogger = diagnosticLogger

        let configuration = Self.makeWebViewConfiguration(
            for: WebPanelDefinition.localDocument.capabilityProfile
        )
        let webView = FocusAwareWKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        // Expose the panel to Safari Web Inspector for debug builds so reveal
        // measurements can be inspected directly in WKWebView rather than
        // guessed at through Chromium approximations.
        webView.isInspectable = true
        #endif
        self.webView = webView
        self.bridgeScriptEvaluator = bridgeScriptEvaluator ?? { script, completion in
            webView.evaluateJavaScript(script, completionHandler: completion)
        }
        self.reloadDebounceNanoseconds = reloadDebounceNanoseconds

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
            pendingRevealLine: pendingRevealLine,
            currentAssetPath: currentAssetURL?.path,
            currentBootstrap: currentBootstrap,
            searchState: searchStateValue,
            isSearchFieldFocused: searchFieldFocused
        )
    }

    private func diagnosticMetadata(extra: [String: String] = [:]) -> [String: String] {
        var metadata: [String: String] = [
            "panel_id": panelID.uuidString,
            "host_lifecycle_state": String(describing: lifecycleState),
            "bridge_ready": isPanelBridgeReady ? "true" : "false",
            "search_controller_ready": isSearchControllerReady ? "true" : "false",
            "has_bootstrap": currentBootstrap != nil ? "true" : "false",
            "has_pending_bootstrap_script": pendingBootstrapScript != nil ? "true" : "false",
        ]

        if let filePath = currentBootstrap?.filePath ?? session?.filePath ?? currentWebState?.filePath,
           filePath.isEmpty == false {
            metadata["file_path"] = filePath
        }

        let displayName = currentBootstrap?.displayName ?? session?.displayName ?? currentWebState?.title
        if let displayName, displayName.isEmpty == false {
            metadata["display_name"] = displayName
        }

        if let currentAssetPath = currentAssetURL?.path, currentAssetPath.isEmpty == false {
            metadata["asset_path"] = currentAssetPath
        }

        if let pendingRevealLine {
            metadata["pending_reveal_line"] = String(pendingRevealLine)
        }

        for (key, value) in extra where value.isEmpty == false {
            metadata[key] = value
        }

        return metadata
    }

    private func logDiagnostic(
        _ level: ToasttyLogLevel,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        diagnosticLogger(level, message, diagnosticMetadata(extra: metadata))
    }

    private func clampedDiagnosticValue(_ value: String?, limit: Int = 2_000) -> String? {
        guard let value, value.isEmpty == false else {
            return nil
        }
        guard value.count > limit else {
            return value
        }
        let endIndex = value.index(value.startIndex, offsetBy: limit - 1)
        return "\(value[..<endIndex])…"
    }

    #if DEBUG
    func simulateBridgeReadyForTesting() {
        handleBridgeEvent(.bridgeReady)
    }

    func simulateBridgeMessageForTesting(_ body: [String: Any]) {
        guard let event = BridgeEvent(messageBody: body) else {
            return
        }
        handleBridgeEvent(event)
    }
    #endif

    func canSaveFromCommand() -> Bool {
        session?.canSaveFromCommand == true
    }

    func canEnterEditFromCommand() -> Bool {
        guard let session else { return false }
        return session.filePath != nil && session.isEditing == false
    }

    @discardableResult
    func enterEditFromCommand() -> Bool {
        guard canEnterEditFromCommand() else {
            return false
        }
        enterEditMode()
        return true
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

    func searchState() -> LocalDocumentSearchState? {
        searchStateValue
    }

    func isSearchFieldFocused() -> Bool {
        searchFieldFocused
    }

    func setSearchFieldFocused(_ focused: Bool) {
        guard searchFieldFocused != focused else {
            return
        }
        objectWillChange.send()
        searchFieldFocused = focused
    }

    @discardableResult
    func startSearch() -> Bool {
        let isNewSearchSession = searchStateValue?.isPresented != true
        ensurePanelAppLoaded()
        if isNewSearchSession {
            cancelPendingSearchResult()
            shouldRefreshSearchAfterBootstrap = false
            searchSessionResetter(webView)
        }
        var nextState = searchStateValue ?? LocalDocumentSearchState(
            isPresented: true,
            query: ""
        )
        nextState.isPresented = true
        nextState.focusRequestID = UUID()
        publishSearchState(nextState)
        return true
    }

    func updateSearchQuery(_ query: String) {
        guard var searchState = searchStateValue else {
            return
        }
        guard searchState.query != query else {
            return
        }

        searchState.query = query
        searchState.lastMatchFound = nil
        publishSearchState(searchState)

        if query.isEmpty {
            cancelPendingSearchResult()
            shouldRefreshSearchAfterBootstrap = false
            clearSearchHighlights()
            return
        }

        if shouldRefreshSearchForCurrentWebContent() {
            shouldRefreshSearchAfterBootstrap = true
        }
        ensurePanelAppLoaded()
        _ = performSearch(.setQuery(query))
    }

    @discardableResult
    func findNext() -> Bool {
        guard let query = searchStateValue?.query,
              query.isEmpty == false else {
            return false
        }
        ensurePanelAppLoaded()
        if shouldRefreshSearchForCurrentWebContent() {
            shouldRefreshSearchAfterBootstrap = true
        }
        return performSearch(.findNext(query))
    }

    @discardableResult
    func findPrevious() -> Bool {
        guard let query = searchStateValue?.query,
              query.isEmpty == false else {
            return false
        }
        ensurePanelAppLoaded()
        if shouldRefreshSearchForCurrentWebContent() {
            shouldRefreshSearchAfterBootstrap = true
        }
        return performSearch(.findPrevious(query))
    }

    @discardableResult
    func endSearch() -> Bool {
        guard searchStateValue != nil else {
            return false
        }

        cancelPendingSearchResult()
        shouldRefreshSearchAfterBootstrap = false
        clearSearchHighlights()
        publishSearchState(nil)
        setSearchFieldFocused(false)
        return true
    }

    func enterEditMode() {
        guard var session else { return }
        guard session.beginEditing() else { return }
        objectWillChange.send()
        self.session = session
        pendingRevealLine = nil
        updateCurrentBootstrap()
        markSearchRefreshAfterVisibleContentChangeIfNeeded()
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
        refreshSearchForCurrentVisibleContentIfNeeded()
    }

    func cancelEditMode(baseContentRevision: Int) {
        guard var session else { return }
        guard session.cancelEditing(baseContentRevision: baseContentRevision) else { return }
        objectWillChange.send()
        self.session = session
        updateCurrentBootstrap()
        markSearchRefreshAfterVisibleContentChangeIfNeeded()
        pushPendingBootstrapIfPossible()
    }

    func save(baseContentRevision: Int) {
        startSave(baseContentRevision: baseContentRevision, allowConflictOverwrite: false)
    }

    func overwriteAfterConflict(baseContentRevision: Int) {
        startSave(baseContentRevision: baseContentRevision, allowConflictOverwrite: true)
    }

    func openInDefaultApp() {
        guard let filePath = session?.filePath else {
            return
        }

        _ = externalFileOpener(URL(filePath: filePath))
    }

    @discardableResult
    func focusWebView() -> Bool {
        guard let window = webView.window else {
            return false
        }
        return window.makeFirstResponder(webView)
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

    func requestReveal(lineNumber: Int) {
        guard lineNumber > 0 else {
            pendingRevealLine = nil
            return
        }

        pendingRevealLine = lineNumber
        pushPendingRevealIfPossible()
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
        return bridgeCommandJavaScript(command: "bridge.receiveBootstrap(\(json));")
    }

    nonisolated static func textScaleJavaScript(for textScale: Double) -> String {
        bridgeCommandJavaScript(
            command: "bridge.setTextScale(\(String(format: "%.4f", textScale)));"
        )
    }

    nonisolated static func revealLineJavaScript(for lineNumber: Int) -> String {
        bridgeCommandJavaScript(command: "bridge.revealLine(\(lineNumber));")
    }

    nonisolated static func bridgeCommandJavaScript(command: String) -> String {
        """
        (() => {
            const bridge = window.ToasttyLocalDocumentPanel;
            if (!bridge) {
                return false;
            }
            \(command)
            return true;
        })();
        """
    }

    nonisolated static func bridgeCommandWasDelivered(_ result: Any?) -> Bool {
        if let result = result as? Bool {
            return result
        }
        if let result = result as? NSNumber {
            return result.boolValue
        }
        return false
    }

    nonisolated static var keyboardNavigationJavaScript: String {
        """
        (() => {
          const installFlag = "__toasttyLocalDocumentKeyboardNavigationInstalled";
          if (window[installFlag] === true) {
            return;
          }
          window[installFlag] = true;

          const scrollContainerSelector = ".local-document-code-scroll";
          const handledKeys = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]);

          const isInteractiveTarget = (element) => {
            if (!(element instanceof Element)) {
              return false;
            }

            if (element instanceof HTMLTextAreaElement ||
                element instanceof HTMLInputElement ||
                element instanceof HTMLSelectElement ||
                element instanceof HTMLButtonElement ||
                element instanceof HTMLAnchorElement) {
              return true;
            }

            return element.isContentEditable ||
              element.closest("textarea, input, select, button, a[href], [contenteditable='true'], [contenteditable='']");
          };

          const scrollStep = (container, axis) => {
            const lineHeight = Number.parseFloat(window.getComputedStyle(container).lineHeight);
            const baseStep = Number.isFinite(lineHeight) && lineHeight > 0 ? lineHeight : 20;
            return axis === "y" ? Math.max(baseStep * 3, 36) : Math.max(baseStep * 2, 32);
          };

          document.addEventListener("keydown", (event) => {
            if (event.defaultPrevented ||
                event.metaKey ||
                event.ctrlKey ||
                event.altKey ||
                event.shiftKey ||
                handledKeys.has(event.key) === false) {
              return;
            }

            const eventTarget = event.target instanceof Element ? event.target : document.activeElement;
            if (isInteractiveTarget(eventTarget)) {
              return;
            }

            const container = document.querySelector(scrollContainerSelector);
            if (!(container instanceof HTMLElement)) {
              return;
            }

            let deltaLeft = 0;
            let deltaTop = 0;
            switch (event.key) {
            case "ArrowUp":
              deltaTop = -scrollStep(container, "y");
              break;
            case "ArrowDown":
              deltaTop = scrollStep(container, "y");
              break;
            case "ArrowLeft":
              deltaLeft = -scrollStep(container, "x");
              break;
            case "ArrowRight":
              deltaLeft = scrollStep(container, "x");
              break;
            default:
              return;
            }

            const canScrollVertically = container.scrollHeight > container.clientHeight + 1;
            const canScrollHorizontally = container.scrollWidth > container.clientWidth + 1;
            if ((deltaTop !== 0 && canScrollVertically === false) ||
                (deltaLeft !== 0 && canScrollHorizontally === false)) {
              return;
            }

            container.scrollBy({ left: deltaLeft, top: deltaTop, behavior: "auto" });
            event.preventDefault();
          }, { capture: true });
        })();
        """
    }

    static func makeWebViewConfiguration(
        for capabilityProfile: WebPanelCapabilityProfile
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: keyboardNavigationJavaScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
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
        let classification = LocalDocumentClassifier.classification(
            format: session.format,
            filePath: session.filePath
        )
        let highlightState = highlightState(
            classification: classification,
            content: session.visibleContent,
            diskRevision: session.diskRevision
        )
        return LocalDocumentPanelBootstrap(
            filePath: session.filePath,
            displayName: session.displayName,
            format: session.format,
            syntaxLanguage: classification.syntaxLanguage,
            formatLabel: classification.formatLabel,
            highlightState: highlightState,
            shouldHighlight: shouldHighlight(highlightState: highlightState),
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

    nonisolated static func searchJavaScript(for command: LocalDocumentSearchCommand) -> String? {
        let payload: [String: Any]
        switch command {
        case .setQuery(let query):
            payload = ["type": "setQuery", "query": query]
        case .findNext(let query):
            payload = ["type": "next", "query": query]
        case .findPrevious(let query):
            payload = ["type": "previous", "query": query]
        case .clear:
            payload = ["type": "clear"]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }

        return """
        (() => {
          const panel = window.ToasttyLocalDocumentPanel;
          if (!panel?.performSearchCommand) {
            return null;
          }
          return panel.performSearchCommand(\(json));
        })();
        """
    }

    nonisolated static func searchExecutionResult(from result: Any?) -> Bool? {
        if result == nil || result is NSNull {
            return nil
        }
        if let dictionary = result as? [String: Any],
           let matchFound = searchExecutionResultValue(from: dictionary["matchFound"]) {
            return matchFound
        }
        if let dictionary = result as? [AnyHashable: Any],
           let matchFound = searchExecutionResultValue(from: dictionary["matchFound"]) {
            return matchFound
        }
        return searchExecutionResultValue(from: result)
    }

    nonisolated private static func searchExecutionResultValue(from value: Any?) -> Bool? {
        if let matchFound = value as? Bool {
            return matchFound
        }
        if let matchFound = value as? NSNumber {
            return matchFound.boolValue
        }
        return nil
    }

    @MainActor
    private static func resetSearchSession(in webView: FocusAwareWKWebView) {
        let script = """
        (() => {
          const panel = window.ToasttyLocalDocumentPanel;
          if (!panel?.resetSearchState) {
            return false;
          }
          panel.resetSearchState();
          return true;
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in }
    }
}

private extension LocalDocumentPanelRuntime {
    enum JavaScriptConsoleLevel: String {
        case warn
        case error
    }

    enum BridgeEvent {
        case enterEdit
        case openInDefaultApp
        case draftDidChange(content: String, baseContentRevision: Int)
        case save(baseContentRevision: Int)
        case cancelEdit(baseContentRevision: Int)
        case overwriteAfterConflict(baseContentRevision: Int)
        case bridgeReady
        case consoleMessage(level: JavaScriptConsoleLevel, message: String)
        case javascriptError(
            message: String,
            source: String?,
            line: Int?,
            column: Int?,
            stack: String?
        )
        case unhandledRejection(reason: String, stack: String?)
        case renderReady(displayName: String, contentRevision: Int, isEditing: Bool)
        case searchControllerReady
        case searchControllerUnavailable

        init?(messageBody: Any) {
            guard let body = messageBody as? [String: Any],
                  let type = body["type"] as? String else {
                return nil
            }

            func optionalString(_ key: String) -> String? {
                body[key] as? String
            }

            func optionalInt(_ key: String) -> Int? {
                if let intValue = body[key] as? Int {
                    return intValue
                }
                return (body[key] as? NSNumber)?.intValue
            }

            func boolValue(_ key: String) -> Bool? {
                if let boolValue = body[key] as? Bool {
                    return boolValue
                }
                return (body[key] as? NSNumber)?.boolValue
            }

            switch type {
            case "enterEdit":
                self = .enterEdit
            case "openInDefaultApp":
                self = .openInDefaultApp
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
            case "bridgeReady":
                self = .bridgeReady
            case "consoleMessage":
                guard let rawLevel = body["level"] as? String,
                      let level = JavaScriptConsoleLevel(rawValue: rawLevel),
                      let message = body["message"] as? String else {
                    return nil
                }
                self = .consoleMessage(level: level, message: message)
            case "javascriptError":
                guard let message = body["message"] as? String else {
                    return nil
                }
                self = .javascriptError(
                    message: message,
                    source: optionalString("source"),
                    line: optionalInt("line"),
                    column: optionalInt("column"),
                    stack: optionalString("stack")
                )
            case "unhandledRejection":
                guard let reason = body["reason"] as? String else {
                    return nil
                }
                self = .unhandledRejection(reason: reason, stack: optionalString("stack"))
            case "renderReady":
                guard let displayName = body["displayName"] as? String,
                      let contentRevision = optionalInt("contentRevision"),
                      let isEditing = boolValue("isEditing") else {
                    return nil
                }
                self = .renderReady(
                    displayName: displayName,
                    contentRevision: contentRevision,
                    isEditing: isEditing
                )
            case "searchControllerReady":
                self = .searchControllerReady
            case "searchControllerUnavailable":
                self = .searchControllerUnavailable
            default:
                return nil
            }
        }
    }

    func handleBridgeEvent(_ event: BridgeEvent) {
        switch event {
        case .enterEdit:
            enterEditMode()
        case .openInDefaultApp:
            openInDefaultApp()
        case .draftDidChange(let content, let baseContentRevision):
            updateDraftContent(content, baseContentRevision: baseContentRevision)
        case .save(let baseContentRevision):
            save(baseContentRevision: baseContentRevision)
        case .cancelEdit(let baseContentRevision):
            cancelEditMode(baseContentRevision: baseContentRevision)
        case .overwriteAfterConflict(let baseContentRevision):
            overwriteAfterConflict(baseContentRevision: baseContentRevision)
        case .bridgeReady:
            logDiagnostic(.debug, "Local document bridge ready")
            isPanelBridgeReady = true
            pushPendingBootstrapIfPossible()
        case .consoleMessage(let level, let message):
            let metadata = [
                "console_level": level.rawValue,
                "console_message": clampedDiagnosticValue(message) ?? "<empty>",
            ]
            switch level {
            case .warn:
                logDiagnostic(.warning, "Local document JavaScript console warning", metadata: metadata)
            case .error:
                logDiagnostic(.error, "Local document JavaScript console error", metadata: metadata)
            }
        case .javascriptError(let message, let source, let line, let column, let stack):
            var metadata = [
                "javascript_message": clampedDiagnosticValue(message) ?? "<empty>",
            ]
            if let source = clampedDiagnosticValue(source) {
                metadata["javascript_source"] = source
            }
            if let line {
                metadata["javascript_line"] = String(line)
            }
            if let column {
                metadata["javascript_column"] = String(column)
            }
            if let stack = clampedDiagnosticValue(stack) {
                metadata["javascript_stack"] = stack
            }
            logDiagnostic(.error, "Local document JavaScript error", metadata: metadata)
        case .unhandledRejection(let reason, let stack):
            var metadata = [
                "javascript_reason": clampedDiagnosticValue(reason) ?? "<empty>",
            ]
            if let stack = clampedDiagnosticValue(stack) {
                metadata["javascript_stack"] = stack
            }
            logDiagnostic(.error, "Local document JavaScript unhandled rejection", metadata: metadata)
        case .renderReady(let displayName, let contentRevision, let isEditing):
            logDiagnostic(
                .debug,
                "Local document render ready",
                metadata: [
                    "render_display_name": clampedDiagnosticValue(displayName) ?? "<empty>",
                    "render_content_revision": String(contentRevision),
                    "render_is_editing": isEditing ? "true" : "false",
                ]
            )
        case .searchControllerReady:
            isSearchControllerReady = true
            refreshSearchAfterBootstrapIfNeeded()
        case .searchControllerUnavailable:
            isSearchControllerReady = false
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
            self.markSearchRefreshAfterVisibleContentChangeIfNeeded()
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
            markSearchRefreshAfterVisibleContentChangeIfNeeded()
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
        markSearchRefreshAfterVisibleContentChangeIfNeeded()
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
            logDiagnostic(.error, "Local document assets unavailable")
            isPanelBridgeReady = false
            isSearchControllerReady = false
            webView.loadHTMLString(fallbackHTML, baseURL: nil)
            currentAssetURL = nil
            return
        }

        if currentAssetURL == entryURL {
            pushPendingBootstrapIfPossible()
            return
        }

        isPanelBridgeReady = false
        isSearchControllerReady = false
        currentAssetURL = entryURL
        logDiagnostic(
            .debug,
            "Loading local document panel app",
            metadata: [
                "entry_path": entryURL.path,
                "read_access_path": assetDirectoryURL.path,
            ]
        )
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

        guard isPanelBridgeReady else {
            return
        }

        if pendingBootstrapScript == nil {
            stageCurrentBootstrapScript()
        }
        guard let pendingBootstrapScript else { return }
        bridgeScriptEvaluator(pendingBootstrapScript) { [weak self] result, error in
            guard let self else { return }
            if error == nil, Self.bridgeCommandWasDelivered(result) {
                self.pendingBootstrapScript = nil
                self.pushPendingRevealIfPossible()
                self.refreshSearchAfterBootstrapIfNeeded()
                self.logDiagnostic(.debug, "Delivered local document bootstrap to page")
                return
            }
            var metadata: [String: String] = [:]
            if let error {
                metadata["error"] = self.clampedDiagnosticValue(error.localizedDescription) ?? "unknown"
            } else {
                metadata["delivery_result"] = String(describing: result)
            }
            self.logDiagnostic(
                .debug,
                "Local document bootstrap delivery deferred",
                metadata: metadata
            )
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
        bridgeScriptEvaluator(script) { [weak self] result, error in
            guard let self else { return }
            guard error == nil, Self.bridgeCommandWasDelivered(result) else {
                self.pendingBootstrapScript = nil
                var metadata: [String: String] = [:]
                if let error {
                    metadata["error"] = self.clampedDiagnosticValue(error.localizedDescription) ?? "unknown"
                } else {
                    metadata["delivery_result"] = String(describing: result)
                }
                self.logDiagnostic(
                    .debug,
                    "Local document text scale update deferred",
                    metadata: metadata
                )
                self.pushPendingBootstrapIfPossible()
                return
            }
            self.logDiagnostic(
                .debug,
                "Delivered local document text scale update",
                metadata: ["text_scale": String(format: "%.4f", self.currentTextScale)]
            )
        }
    }

    func pushPendingRevealIfPossible() {
        guard let pendingRevealLine else { return }

        if session?.isEditing == true {
            self.pendingRevealLine = nil
            return
        }

        // Header-driven runtime creation can queue a line reveal before the
        // panel body has applied its WebPanelState. Keep that reveal pending
        // instead of preloading the web app without document state, which can
        // leave the panel stranded in its blank loading shell.
        guard currentWebState != nil else {
            return
        }

        // Keep first-load ownership on the bootstrap path. Loading the panel
        // shell from a queued reveal before document bootstrap exists can
        // leave the newly opened panel showing its blank waiting state until a
        // later interaction retries the reveal.
        guard currentBootstrap != nil else {
            return
        }

        guard let entryURL else {
            ensurePanelAppLoaded()
            return
        }

        if currentAssetURL != entryURL {
            ensurePanelAppLoaded()
            return
        }

        guard pendingBootstrapScript == nil else {
            return
        }

        let script = Self.revealLineJavaScript(for: pendingRevealLine)
        bridgeScriptEvaluator(script) { [weak self] result, error in
            guard let self else { return }
            if error == nil, Self.bridgeCommandWasDelivered(result) {
                self.pendingRevealLine = nil
                self.logDiagnostic(
                    .debug,
                    "Delivered local document line reveal",
                    metadata: ["revealed_line": String(pendingRevealLine)]
                )
                return
            }
            if error != nil {
                self.logDiagnostic(
                    .debug,
                    "Local document line reveal deferred",
                    metadata: [
                        "revealed_line": String(pendingRevealLine),
                        "error": self.clampedDiagnosticValue(error?.localizedDescription) ?? "unknown",
                    ]
                )
                self.pushPendingBootstrapIfPossible()
                return
            }
            self.logDiagnostic(
                .debug,
                "Local document line reveal bridge unavailable",
                metadata: [
                    "revealed_line": String(pendingRevealLine),
                    "delivery_result": String(describing: result),
                ]
            )
        }
    }

    func stageCurrentBootstrapScript() {
        guard let currentBootstrap,
              let script = Self.bootstrapJavaScript(for: currentBootstrap) else {
            return
        }
        pendingBootstrapScript = script
    }

    @discardableResult
    private func performSearch(_ command: LocalDocumentSearchCommand) -> Bool {
        guard let searchState = searchStateValue,
              searchState.isPresented,
              let query = command.query,
              query.isEmpty == false else {
            return false
        }

        activeSearchRequestGeneration &+= 1
        let requestGeneration = activeSearchRequestGeneration

        searchExecutor(webView, command) { [weak self] matchFound in
            guard let self,
                  requestGeneration == self.activeSearchRequestGeneration,
                  var currentSearchState = self.searchStateValue,
                  currentSearchState.isPresented,
                  currentSearchState.query == query else {
                return
            }

            guard let matchFound else {
                self.shouldRefreshSearchAfterBootstrap = true
                self.refreshSearchAfterBootstrapIfNeeded()
                return
            }

            currentSearchState.lastMatchFound = matchFound
            self.publishSearchState(currentSearchState)
        }
        return true
    }

    private func clearSearchHighlights() {
        searchExecutor(webView, .clear) { _ in }
    }

    private func publishSearchState(_ nextState: LocalDocumentSearchState?) {
        guard searchStateValue != nextState else {
            return
        }
        objectWillChange.send()
        searchStateValue = nextState
    }

    private func cancelPendingSearchResult() {
        activeSearchRequestGeneration &+= 1
    }

    private func refreshSearchForCurrentVisibleContentIfNeeded() {
        guard shouldRefreshSearchForCurrentWebContent() == false,
              let searchState = searchStateValue,
              searchState.isPresented,
              searchState.query.isEmpty == false else {
            return
        }

        _ = performSearch(.setQuery(searchState.query))
    }

    private func markSearchRefreshAfterVisibleContentChangeIfNeeded() {
        guard let searchState = searchStateValue,
              searchState.isPresented,
              searchState.query.isEmpty == false else {
            return
        }
        shouldRefreshSearchAfterBootstrap = true
    }

    private func refreshSearchAfterBootstrapIfNeeded() {
        guard shouldRefreshSearchAfterBootstrap else {
            return
        }
        guard shouldRefreshSearchForCurrentWebContent() == false else {
            return
        }

        guard let searchState = searchStateValue,
              searchState.isPresented,
              searchState.query.isEmpty == false else {
            shouldRefreshSearchAfterBootstrap = false
            return
        }

        shouldRefreshSearchAfterBootstrap = false
        _ = performSearch(.setQuery(searchState.query))
    }

    private func shouldRefreshSearchForCurrentWebContent() -> Bool {
        guard let entryURL else {
            return false
        }
        return currentAssetURL != entryURL ||
            pendingBootstrapScript != nil ||
            isPanelBridgeReady == false ||
            isSearchControllerReady == false
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

    nonisolated static func highlightState(
        classification: LocalDocumentClassification,
        content: String,
        diskRevision: LocalDocumentPanelDiskRevision?
    ) -> LocalDocumentHighlightState {
        // Experiment: markdown is rendered as code, so it now follows the same
        // size threshold as yaml/toml instead of always highlighting.
        guard diskRevision != nil else {
            return .unavailable
        }

        guard supportsHighlighting(classification: classification) else {
            return .unsupportedFormat
        }

        if content.utf8.count > syntaxHighlightThresholdBytes {
            return .disabledForLargeFile
        }

        return .enabled
    }

    nonisolated static func shouldHighlight(highlightState: LocalDocumentHighlightState) -> Bool {
        highlightState == .enabled
    }

    nonisolated static func supportsHighlighting(
        classification: LocalDocumentClassification
    ) -> Bool {
        switch classification.format {
        case .markdown:
            return true
        case .yaml, .toml, .json, .jsonl, .xml, .shell, .code:
            return classification.syntaxLanguage != nil
        case .config, .csv, .tsv:
            return classification.syntaxLanguage != nil
        }
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
        logDiagnostic(
            .debug,
            "Local document web view finished navigation",
            metadata: [
                "navigated_url": webView.url?.absoluteString ?? "<none>",
            ]
        )
        pushPendingBootstrapIfPossible()
        pushPendingRevealIfPossible()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        _ = navigation
        logDiagnostic(
            .warning,
            "Local document web view navigation failed",
            metadata: [
                "navigated_url": webView.url?.absoluteString ?? "<none>",
                "error": clampedDiagnosticValue(error.localizedDescription) ?? "unknown",
            ]
        )
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        _ = navigation
        logDiagnostic(
            .warning,
            "Local document web view provisional navigation failed",
            metadata: [
                "navigated_url": webView.url?.absoluteString ?? "<none>",
                "error": clampedDiagnosticValue(error.localizedDescription) ?? "unknown",
            ]
        )
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logDiagnostic(
            .warning,
            "Local document web content process terminated",
            metadata: [
                "navigated_url": webView.url?.absoluteString ?? "<none>",
            ]
        )
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
