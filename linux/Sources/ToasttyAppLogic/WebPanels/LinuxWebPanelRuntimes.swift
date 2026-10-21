import CoreState
import Foundation

// MARK: - Web panel runtime seam (Linux)
//
// The shared `WebPanelRuntimeRegistry` owns one runtime per browser,
// local-document, and Scratchpad panel. On macOS each runtime wraps a
// WKWebView (Sources/App/WebPanels/*PanelRuntime.swift). On Linux these
// classes keep the registry-facing API and forward to a host view the panels
// frontend (WebKitGTK) attaches with `attach(host:)`. Until a host is
// attached, commands report "not handled" and state queries return nil, the
// same answers macOS gives before its web view loads.

/// Implemented by the frontend's WebKitGTK browser panel.
@MainActor
public protocol LinuxBrowserPanelHost: AnyObject {
    func focus() -> Bool
    func load(urlString: String) -> Bool
    func goBack() -> Bool
    func goForward() -> Bool
    func reloadOrStop() -> Bool
    /// Explicit reload (`panel.browser.reload`): always starts a navigation
    /// to `urlString`, revalidating the cache when the view already shows it.
    func reload(urlString: String) -> Bool
    /// Load `webState`'s destination unless the view already shows or
    /// requested it (macOS `synchronizeDisplayedContent`).
    func synchronize(webState: WebPanelState)
    func focusLocationField()
    /// Whether the view is in a window (vs. created off screen to load a
    /// hidden panel in the background).
    var isInWindow: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var isLoading: Bool { get }
    var currentURLString: String? { get }
    var currentTitle: String? { get }
    /// PNG favicon bytes for the current page, if loaded.
    var faviconPNG: Data? { get }
    /// PNG of the visible page (automation screenshots, annotations).
    func captureScreenshotPNG() async throws -> Data
    /// WebKit page zoom (CSS pixel → view point factor).
    var pageZoom: Double { get }
    /// The web view's size in view points (the annotation viewport).
    var viewportSize: CGSize { get }
    /// `window.scrollX/Y` in CSS pixels, or nil when the page cannot answer.
    func pageScrollOffset() async -> CGPoint?
}

/// Main-frame navigation results the browser host reports (WebKitGTK
/// `load-changed`, `load-failed`, `web-process-terminated`). The host omits
/// its internal start/invalid-URL pages and loads superseded by a newer one.
public enum LinuxBrowserNavigationEvent: Equatable, Sendable {
    case started
    case finished
    case failed(domain: String, code: Int, message: String)
}

/// Implemented by the frontend's local-document (Markdown/code) panel.
@MainActor
public protocol LinuxLocalDocumentPanelHost: AnyObject {
    func focus() -> Bool
    var canEnterEdit: Bool { get }
    var canSave: Bool { get }
    var canCancelEdit: Bool { get }
    func enterEdit() -> Bool
    func save() -> Bool
    func cancelEdit() -> Bool
    /// Unsaved draft (`dirtyDraft`) or in-flight save (`saveInProgress`).
    var closeConfirmation: LinuxLocalDocumentCloseConfirmation? { get }
    func reveal(lineNumber: Int)
    func setSearchQuery(_ query: String?)
    func findNext() -> Bool
    func findPrevious() -> Bool
}

public enum LinuxLocalDocumentCloseConfirmation: Sendable, Equatable {
    case dirtyDraft(displayName: String)
    case saveInProgress(displayName: String)
}

/// Implemented by the frontend's Scratchpad panel.
@MainActor
public protocol LinuxScratchpadPanelHost: AnyObject {
    func focus() -> Bool
    /// The panel's document changed (new revision in the document store).
    func reloadDocument()
}

/// Host attachment bookkeeping shared by the Linux runtimes.
@MainActor
struct LinuxWebPanelAttachment {
    private(set) var token: PanelHostAttachmentToken?

    mutating func attach() { token = PanelHostAttachmentToken.next() }
    mutating func detach() { token = nil }

    var lifecycleState: PanelHostLifecycleState {
        token.map { .ready($0) } ?? .detached
    }
}

/// Creates the frontend browser for a panel that has none yet (never shown:
/// another workspace or tab, or restored and not selected), off screen, so
/// automation can load it in the background like macOS's runtime-owned
/// WKWebView. The frontend attaches it through `attach(host:)`.
/// Set by `LinuxAppLogic.setBrowserHostMaterializer(_:)`.
@MainActor
enum LinuxBrowserHostMaterializer {
    static var materialize: (@MainActor (UUID) -> Void)?
}

@MainActor
final class BrowserPanelRuntime: ObservableObject, WebPanelAnnotationRuntime {
    let panelID: UUID
    /// Annotation drafts for the displayed page (macOS keeps the same
    /// session on its WKWebView runtime); see `LinuxWebPanelAnnotationController`.
    let annotationSession = WebPanelAnnotationSession()
    var annotationSource: WebPanelAnnotationSource { .browser }
    /// Created by `LinuxAppLogic.browserAnnotationController(panelID:)`.
    var annotationController: LinuxWebPanelAnnotationController?
    private var annotationObservation: AnyCancellable?
    private var lastObservedURLStringForPageChange: String?
    private let metadataDidChange: @MainActor (UUID, String?, String?) -> Void
    private let interactionDidRequestFocus: @MainActor (UUID) -> Void
    private let openSecondaryURLHandler: @MainActor (UUID, URL) -> Bool
    private(set) weak var host: (any LinuxBrowserPanelHost)?
    private(set) var webState: WebPanelState?
    private var pendingLocationFieldFocus = false
    // Query-only navigation status (macOS `navigationResult`/`navigationError`).
    private var navigationResult: BrowserNavigationResult = .idle
    private var navigationError: BrowserNavigationError?
    @Published private(set) var faviconImage: NSImage?

    init(
        panelID: UUID,
        metadataDidChange: @escaping @MainActor (UUID, String?, String?) -> Void,
        interactionDidRequestFocus: @escaping @MainActor (UUID) -> Void,
        responderDidRequestFocus: @escaping @MainActor (UUID) -> Void,
        openSecondaryURL: @escaping @MainActor (UUID, URL) -> Bool
    ) {
        _ = responderDidRequestFocus
        self.panelID = panelID
        self.metadataDidChange = metadataDidChange
        self.interactionDidRequestFocus = interactionDidRequestFocus
        openSecondaryURLHandler = openSecondaryURL
        annotationObservation = annotationSession.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private var attachment = LinuxWebPanelAttachment()
    var lifecycleState: PanelHostLifecycleState { attachment.lifecycleState }

    func attach(host: any LinuxBrowserPanelHost) {
        self.host = host
        attachment.attach()
        if pendingLocationFieldFocus {
            pendingLocationFieldFocus = false
            host.focusLocationField()
        }
        objectWillChange.send()
    }

    func detachHost() {
        host = nil
        attachment.detach()
        navigationResult = .idle
        navigationError = nil
        annotationSession.invalidateForContentChange()
        objectWillChange.send()
    }

    /// Creates an off-screen host when the frontend has not built one, so
    /// state queries and reloads load hidden panels (see
    /// `LinuxBrowserHostMaterializer`).
    @discardableResult
    private func ensureHost() -> (any LinuxBrowserPanelHost)? {
        if host == nil { LinuxBrowserHostMaterializer.materialize?(panelID) }
        return host
    }

    func hostDidReport(_ event: LinuxBrowserNavigationEvent) {
        switch event {
        case .started:
            navigationResult = .loading
            navigationError = nil
        case .finished:
            // WebKit also reports a failed load as finished.
            if navigationResult == .loading { navigationResult = .finished }
        case .failed(let domain, let code, let message):
            // macOS `finishNavigation`: a settled result stays settled.
            guard navigationResult == .loading || navigationResult == .idle else { return }
            navigationResult = .failed
            navigationError = BrowserNavigationError(
                NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
            )
        }
    }

    /// Frontend callbacks.
    func hostDidUpdateMetadata(title: String?, url: String?) {
        metadataDidChange(panelID, title, url)
    }

    func hostDidUpdateFavicon(png: Data?) {
        faviconImage = png.flatMap { NSImage(pngData: $0, size: CGSize(width: 16, height: 16)) }
    }

    func hostDidRequestFocus() {
        interactionDidRequestFocus(panelID)
    }

    func hostRequestsSecondaryOpen(_ url: URL) -> Bool {
        openSecondaryURLHandler(panelID, url)
    }

    func apply(webState: WebPanelState) {
        self.webState = webState
        ensureHost()?.synchronize(webState: webState)
    }

    /// Unlike the toolbar toggle, an explicit reload always starts navigation.
    @discardableResult
    func reload(webState: WebPanelState) -> Bool {
        self.webState = webState
        guard let urlString = webState.restorableURL, let host = ensureHost() else { return false }
        navigationResult = .loading
        navigationError = nil
        return host.reload(urlString: urlString)
    }

    func setEffectivelyVisible(_ visible: Bool) {
        _ = visible
    }

    func requestLocationFieldFocus() {
        if let host {
            host.focusLocationField()
        } else {
            pendingLocationFieldFocus = true
        }
    }

    func focusWebView() -> Bool { host?.focus() ?? false }

    func loadUserEnteredURL(_ value: String) -> Bool {
        guard let normalized = Self.normalizedUserEnteredURLString(value) else { return false }
        guard let host else { return false }
        clearAnnotationsForPageChange()
        return host.load(urlString: normalized)
    }

    // MARK: Annotations (macOS BrowserPanelRuntime's WebPanelAnnotationRuntime)

    var annotationDisplayZoom: CGFloat { CGFloat(host?.pageZoom ?? 1) }

    func currentAnnotationViewport() async -> BrowserAnnotationViewport {
        let viewportSize = host?.viewportSize ?? .zero
        guard let host, let scrollOffset = await host.pageScrollOffset() else {
            return BrowserAnnotationViewport(scrollOffset: .zero, viewportSize: viewportSize)
        }
        return BrowserAnnotationViewport(scrollOffset: scrollOffset, viewportSize: host.viewportSize)
    }

    func captureAnnotationSection(capturedAt: Date = Date()) async throws -> BrowserAnnotationCapturedSection {
        guard let host else { throw LinuxWebPanelError.noHost }
        let viewportSize = host.viewportSize
        guard viewportSize.width > 0, viewportSize.height > 0 else { throw BrowserPanelScreenshotError.emptySnapshotBounds }
        let pngData = try await host.captureScreenshotPNG()
        let viewport = await currentAnnotationViewport()
        return BrowserAnnotationCapturedSection(
            pngData: pngData,
            url: WebPanelState.normalizedCurrentURL(host.currentURLString),
            title: WebPanelState.normalizedTitle(host.currentTitle),
            scrollOffset: viewport.scrollOffset,
            viewportSize: viewport.viewportSize,
            capturedAt: capturedAt
        )
    }

    /// A main-frame navigation committed (WebKit `load-changed` COMMITTED,
    /// macOS `didCommit`): drafts belong to the previous page.
    func hostDidCommitNavigation(urlString: String?) {
        clearAnnotationsForPageChange()
        lastObservedURLStringForPageChange = Self.annotationPageURLString(urlString)
    }

    /// The view's URI changed (including same-document hash/pushState
    /// routes). Port of macOS `handleObservedURLChange`.
    @discardableResult
    func handleObservedURLChange(_ observedURLString: String?, isPageLoading: Bool = false) -> Bool {
        let currentURLString = Self.annotationPageURLString(observedURLString)
        guard isPageLoading == false else { return false }
        defer { lastObservedURLStringForPageChange = currentURLString }
        guard let previousURLString = lastObservedURLStringForPageChange,
              let currentURLString,
              previousURLString != currentURLString else {
            return false
        }
        clearAnnotationsForPageChange()
        return true
    }

    private func clearAnnotationsForPageChange() {
        annotationSession.invalidateForContentChange()
    }

    private static func annotationPageURLString(_ urlString: String?) -> String? {
        guard let normalizedURLString = WebPanelState.normalizedCurrentURL(urlString),
              normalizedURLString.caseInsensitiveCompare("about:blank") != .orderedSame else {
            return nil
        }
        return normalizedURLString
    }

    func automationState() -> BrowserPanelRuntimeAutomationState {
        BrowserPanelRuntimeAutomationState(
            // An off-screen host is detached, as macOS reports a WKWebView
            // outside any window.
            lifecycleState: host?.isInWindow == true ? lifecycleState : .detached,
            pageZoom: host?.pageZoom ?? webState?.effectiveBrowserPageZoom ?? WebPanelState.defaultBrowserPageZoom,
            observedURL: WebPanelState.normalizedCurrentURL(host?.currentURLString),
            title: WebPanelState.normalizedTitle(host?.currentTitle),
            isLoading: host?.isLoading ?? false,
            navigationState: navigationResult,
            navigationError: navigationError
        )
    }

    func goBack() -> Bool { host?.goBack() ?? false }
    func goForward() -> Bool { host?.goForward() ?? false }
    func reloadOrStop() -> Bool { host?.reloadOrStop() ?? false }

    func captureVisibleScreenshot() async throws -> NSImage {
        guard let host else { throw LinuxWebPanelError.noHost }
        let png = try await host.captureScreenshotPNG()
        guard let image = NSImage(pngData: png, size: .zero) else { throw LinuxWebPanelError.invalidImage }
        return image
    }

    /// Same normalization as macOS: bare hosts get https, file paths get file://.
    static func normalizedUserEnteredURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).absoluteString
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, scheme.isEmpty == false,
           trimmed.contains("://") || ["about", "data", "mailto"].contains(scheme.lowercased()) {
            return url.absoluteString
        }
        if trimmed.contains(" ") == false, trimmed.contains(".") || trimmed.hasPrefix("localhost") {
            return "https://\(trimmed)"
        }
        return nil
    }
}

@MainActor
final class LocalDocumentPanelRuntime: ObservableObject {
    let panelID: UUID
    private let metadataDidChange: @MainActor (UUID, String?, String?) -> Void
    private let interactionDidRequestFocus: @MainActor (UUID) -> Void
    private(set) weak var host: (any LinuxLocalDocumentPanelHost)?
    private(set) var webState: WebPanelState?
    private var pendingRevealLine: Int?
    private var search: LocalDocumentSearchState?
    private var searchFieldFocused = false

    init(
        panelID: UUID,
        metadataDidChange: @escaping @MainActor (UUID, String?, String?) -> Void,
        interactionDidRequestFocus: @escaping @MainActor (UUID) -> Void,
        responderDidRequestFocus: @escaping @MainActor (UUID) -> Void
    ) {
        _ = responderDidRequestFocus
        self.panelID = panelID
        self.metadataDidChange = metadataDidChange
        self.interactionDidRequestFocus = interactionDidRequestFocus
    }

    private var attachment = LinuxWebPanelAttachment()
    var lifecycleState: PanelHostLifecycleState { attachment.lifecycleState }
    /// Set by the frontend when the panel follows the system color scheme.
    var currentTheme: LocalDocumentPanelTheme = .dark

    func attach(host: any LinuxLocalDocumentPanelHost) {
        self.host = host
        attachment.attach()
        if let pendingRevealLine {
            self.pendingRevealLine = nil
            host.reveal(lineNumber: pendingRevealLine)
        }
        objectWillChange.send()
    }

    func detachHost() {
        host = nil
        attachment.detach()
        objectWillChange.send()
    }

    func hostDidUpdateMetadata(title: String?, url: String?) {
        metadataDidChange(panelID, title, url)
    }

    func hostDidRequestFocus() {
        interactionDidRequestFocus(panelID)
    }

    func apply(webState: WebPanelState) {
        self.webState = webState
    }

    func automationState() -> LocalDocumentPanelRuntimeAutomationState {
        LocalDocumentPanelRuntimeAutomationState(
            lifecycleState: lifecycleState,
            currentTheme: currentTheme,
            hasPendingBootstrapScript: false,
            pendingRevealLine: pendingRevealLine,
            currentAssetPath: nil,
            currentBootstrap: nil,
            searchState: search,
            isSearchFieldFocused: searchFieldFocused
        )
    }

    func canSaveFromCommand() -> Bool { host?.canSave ?? false }
    func canEnterEditFromCommand() -> Bool { host?.canEnterEdit ?? false }
    func canCancelEditFromCommand() -> Bool { host?.canCancelEdit ?? false }
    func enterEditFromCommand() -> Bool { host?.enterEdit() ?? false }
    func saveFromCommand() -> Bool { host?.save() ?? false }
    func cancelEditFromCommand() -> Bool { host?.cancelEdit() ?? false }

    func closeConfirmationState() -> LocalDocumentCloseConfirmationState? {
        switch host?.closeConfirmation {
        case .dirtyDraft(let displayName):
            LocalDocumentCloseConfirmationState(kind: .dirtyDraft, displayName: displayName)
        case .saveInProgress(let displayName):
            LocalDocumentCloseConfirmationState(kind: .saveInProgress, displayName: displayName)
        case nil:
            nil
        }
    }

    func searchState() -> LocalDocumentSearchState? { search }
    func isSearchFieldFocused() -> Bool { searchFieldFocused }

    func setSearchFieldFocused(_ focused: Bool) {
        guard searchFieldFocused != focused else { return }
        searchFieldFocused = focused
        objectWillChange.send()
    }

    func startSearch() -> Bool {
        if search == nil {
            search = LocalDocumentSearchState(isPresented: true, query: "")
        }
        searchFieldFocused = true
        objectWillChange.send()
        return true
    }

    func updateSearchQuery(_ query: String) {
        guard var state = search else { return }
        state.query = query
        search = state
        host?.setSearchQuery(query)
        objectWillChange.send()
    }

    func findNext() -> Bool {
        guard search != nil else { return false }
        return host?.findNext() ?? false
    }

    func findPrevious() -> Bool {
        guard search != nil else { return false }
        return host?.findPrevious() ?? false
    }

    func endSearch() -> Bool {
        guard search != nil else { return false }
        search = nil
        searchFieldFocused = false
        host?.setSearchQuery(nil)
        objectWillChange.send()
        return true
    }

    func focusWebView() -> Bool { host?.focus() ?? false }

    func requestReveal(lineNumber: Int) {
        if let host {
            host.reveal(lineNumber: lineNumber)
        } else {
            pendingRevealLine = lineNumber
        }
    }
}

@MainActor
final class ScratchpadPanelRuntime: ObservableObject {
    let panelID: UUID
    let documentStore: ScratchpadDocumentStore
    private let metadataDidChange: @MainActor (UUID, String?, String?) -> Void
    private let interactionDidRequestFocus: @MainActor (UUID) -> Void
    private let openExternalLinkHandler: @MainActor (UUID, URL) -> Void
    private(set) weak var host: (any LinuxScratchpadPanelHost)?
    private(set) var webState: WebPanelState?

    init(
        panelID: UUID,
        documentStore: ScratchpadDocumentStore,
        metadataDidChange: @escaping @MainActor (UUID, String?, String?) -> Void,
        interactionDidRequestFocus: @escaping @MainActor (UUID) -> Void,
        responderDidRequestFocus: @escaping @MainActor (UUID) -> Void,
        openExternalLink: @escaping @MainActor (UUID, URL) -> Void
    ) {
        _ = responderDidRequestFocus
        self.panelID = panelID
        self.documentStore = documentStore
        self.metadataDidChange = metadataDidChange
        self.interactionDidRequestFocus = interactionDidRequestFocus
        openExternalLinkHandler = openExternalLink
    }

    private var attachment = LinuxWebPanelAttachment()
    var lifecycleState: PanelHostLifecycleState { attachment.lifecycleState }
    var currentTheme: ScratchpadPanelTheme = .dark

    func attach(host: any LinuxScratchpadPanelHost) {
        self.host = host
        attachment.attach()
        objectWillChange.send()
    }

    func detachHost() {
        host = nil
        attachment.detach()
        objectWillChange.send()
    }

    func hostDidUpdateMetadata(title: String?, url: String?) {
        metadataDidChange(panelID, title, url)
    }

    func hostDidRequestFocus() {
        interactionDidRequestFocus(panelID)
    }

    func hostRequestsExternalLink(_ url: URL) {
        openExternalLinkHandler(panelID, url)
    }

    func apply(webState: WebPanelState) {
        let previousRevision = self.webState?.scratchpad?.revision
        self.webState = webState
        if previousRevision != nil, previousRevision != webState.scratchpad?.revision {
            host?.reloadDocument()
        }
    }

    func automationState() -> ScratchpadPanelRuntimeAutomationState {
        ScratchpadPanelRuntimeAutomationState(
            lifecycleState: lifecycleState,
            currentTheme: currentTheme,
            hasPendingBootstrapScript: false,
            currentAssetPath: nil,
            currentBootstrap: nil,
            recentDiagnostics: []
        )
    }

    func focusWebView() -> Bool { host?.focus() ?? false }

    func setEffectivelyVisible(_ visible: Bool) {
        _ = visible
    }
}

enum LinuxWebPanelError: Error, Equatable {
    case noHost
    case invalidImage
}
