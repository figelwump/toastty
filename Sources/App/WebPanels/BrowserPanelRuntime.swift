import AppKit
import Combine
import CoreState
import Foundation
import WebKit

struct BrowserPanelRuntimeAutomationState: Equatable, Sendable {
    let lifecycleState: PanelHostLifecycleState
    let pageZoom: Double
}

struct BrowserPanelNavigationState: Equatable {
    var displayedURLString: String?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false

    var canReloadOrStop: Bool {
        isLoading || displayedURLString != nil
    }
}

struct FaviconLinkReference: Equatable, Sendable {
    var href: String
    var rel: String
}

struct BrowserPanelFileLoad: Equatable, Sendable {
    var fileURL: URL
    // Parent-directory access lets relative sibling and descendant assets load
    // without widening access past the clicked document's containing folder.
    var readAccessURL: URL
}

@MainActor
private final class BrowserPopupCaptureController: NSObject, WKNavigationDelegate {
    private static let timeoutNanoseconds: UInt64 = 5_000_000_000

    let id = UUID()
    let webView: WKWebView

    private let openSecondaryURL: @MainActor (URL) -> Bool
    private let cleanup: @MainActor (UUID) -> Void
    private var timeoutTask: Task<Void, Never>?

    init(
        configuration: WKWebViewConfiguration,
        openSecondaryURL: @escaping @MainActor (URL) -> Bool,
        cleanup: @escaping @MainActor (UUID) -> Void
    ) {
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.openSecondaryURL = openSecondaryURL
        self.cleanup = cleanup
        super.init()
        webView.navigationDelegate = self
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
            guard let self else { return }
            self.cleanup(self.id)
        }
    }

    func invalidate() {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView.navigationDelegate = nil
    }

    deinit {
        timeoutTask?.cancel()
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if let url = BrowserLinkRoutingRules.popupCaptureURL(navigationAction.request.url) {
            _ = openSecondaryURL(url)
            cleanup(id)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        _ = navigation
        guard let url = BrowserLinkRoutingRules.popupCaptureURL(webView.url) else {
            return
        }

        _ = openSecondaryURL(url)
        cleanup(id)
    }

    func webView(
        _: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        _ = navigation
        _ = error
        cleanup(id)
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        _ = navigation
        _ = error
        cleanup(id)
    }
}

@MainActor
final class BrowserPanelRuntime: NSObject, ObservableObject, PanelHostLifecycleControlling {
    @Published private(set) var navigationState = BrowserPanelNavigationState()
    @Published private(set) var locationFieldFocusRequestID: UUID?
    // Favicon remains runtime-only; it is useful UI chrome but not worth
    // persisting or threading through the core panel state contract.
    @Published private(set) var faviconImage: NSImage?

    private let panelID: UUID
    private let metadataDidChange: @MainActor (UUID, String?, String?) -> Void
    private let openSecondaryURLForPanel: @MainActor (UUID, URL) -> Bool
    private let webView: FocusAwareWKWebView
    private var urlObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var canGoBackObservation: NSKeyValueObservation?
    private var canGoForwardObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private weak var activeSourceContainer: NSView?
    private var activeAttachment: PanelHostAttachmentToken?
    private var pendingDetachAttachment: PanelHostAttachmentToken?
    private var pendingDetachTask: Task<Void, Never>?
    private var lastRequestedURLString: String?
    private var isShowingStartPage = false
    private var faviconRefreshTask: Task<Void, Never>?
    private var pendingFaviconRequestID: UUID?
    private var currentPageZoom: Double = WebPanelState.defaultBrowserPageZoom
    private var popupCaptureControllers: [UUID: BrowserPopupCaptureController] = [:]

    init(
        panelID: UUID,
        metadataDidChange: @escaping @MainActor (UUID, String?, String?) -> Void,
        interactionDidRequestFocus: @escaping @MainActor (UUID) -> Void,
        openSecondaryURL: @escaping @MainActor (UUID, URL) -> Bool = { _, _ in false }
    ) {
        self.panelID = panelID
        self.metadataDidChange = metadataDidChange
        self.openSecondaryURLForPanel = openSecondaryURL
        let configuration = Self.makeWebViewConfiguration(
            for: WebPanelDefinition.browser.capabilityProfile
        )
        let webView = FocusAwareWKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.cursorDiagnosticPanelID = panelID
        webView.cursorDiagnosticPanelKind = WebPanelDefinition.browser.rawValue
        self.webView = webView
        super.init()
        webView.interactionDidRequestFocus = { [panelID] in
            interactionDidRequestFocus(panelID)
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeMetadataChanges()
        publishNavigationState()
    }

    deinit {
        pendingDetachTask?.cancel()
        faviconRefreshTask?.cancel()
        urlObservation?.invalidate()
        titleObservation?.invalidate()
        canGoBackObservation?.invalidate()
        canGoForwardObservation?.invalidate()
        loadingObservation?.invalidate()
        popupCaptureControllers.removeAll()
        let webView = webView
        Task { @MainActor in
            webView.interactionDidRequestFocus = nil
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
        }
    }

    static func normalizedUserEnteredURLString(_ value: String) -> String? {
        guard let trimmed = WebPanelState.normalizedCurrentURL(value) else {
            return nil
        }

        let lowercased = trimmed.lowercased()
        if trimmed.contains("://") ||
            lowercased.hasPrefix("about:") ||
            lowercased.hasPrefix("data:") ||
            lowercased.hasPrefix("file:") {
            return trimmed
        }

        if trimmed.contains(where: \.isWhitespace) {
            return trimmed
        }

        let hostCandidate = hostCandidate(from: trimmed)
        if hostCandidate.isEmpty {
            return trimmed
        }

        if hasNumericPort(hostCandidate) {
            return "http://\(trimmed)"
        }

        if isLocalHost(hostCandidate) || isIPv4Address(hostCandidate) || isBracketedIPv6Address(hostCandidate) {
            return "http://\(trimmed)"
        }

        if hasExplicitScheme(trimmed) {
            return trimmed
        }

        if hostCandidate.contains(".") {
            return "https://\(trimmed)"
        }

        return trimmed
    }

    static func faviconCandidateURLs(linkHrefs: [String], pageURL: URL?) -> [URL] {
        faviconCandidateURLs(
            linkReferences: linkHrefs.map { FaviconLinkReference(href: $0, rel: "icon") },
            pageURL: pageURL
        )
    }

    static func faviconCandidateURLs(linkReferences: [FaviconLinkReference], pageURL: URL?) -> [URL] {
        var candidateURLs: [URL] = []

        func appendCandidate(_ url: URL?) {
            guard let absoluteURL = url?.absoluteURL,
                  let scheme = absoluteURL.scheme?.lowercased(),
                  ["http", "https", "data", "file"].contains(scheme),
                  candidateURLs.contains(absoluteURL) == false else {
                return
            }
            candidateURLs.append(absoluteURL)
        }

        var primaryIconHrefs: [String] = []
        var touchIconHrefs: [String] = []
        var maskIconHrefs: [String] = []

        for reference in linkReferences {
            switch faviconLinkKind(for: reference.rel) {
            case .primary:
                primaryIconHrefs.append(reference.href)
            case .appleTouch:
                touchIconHrefs.append(reference.href)
            case .mask:
                maskIconHrefs.append(reference.href)
            case nil:
                continue
            }
        }

        for href in primaryIconHrefs + touchIconHrefs {
            let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            appendCandidate(URL(string: trimmed, relativeTo: pageURL))
        }

        if let pageURL,
           let scheme = pageURL.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           let host = pageURL.host {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.port = pageURL.port
            components.path = "/favicon.ico"
            appendCandidate(components.url)
        }

        for href in maskIconHrefs {
            let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            appendCandidate(URL(string: trimmed, relativeTo: pageURL))
        }

        return candidateURLs
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

    func attachHost(to container: NSView, attachment: PanelHostAttachmentToken) {
        if let activeAttachment, attachment.generation < activeAttachment.generation {
            return
        }

        pendingDetachTask?.cancel()
        pendingDetachTask = nil
        pendingDetachAttachment = nil
        activeAttachment = attachment
        activeSourceContainer = container

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
            webState.definition == .browser,
            "BrowserPanelRuntime cannot host \(webState.definition.rawValue) panels."
        )
        synchronizeDisplayedContent(with: webState)
        applyPageZoom(webState.effectiveBrowserPageZoom)
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

    func requestLocationFieldFocus() {
        locationFieldFocusRequestID = UUID()
    }

    @discardableResult
    func focusWebView() -> Bool {
        guard let window = webView.window else {
            return false
        }
        return window.makeFirstResponder(webView)
    }

    @discardableResult
    func loadUserEnteredURL(_ value: String) -> Bool {
        guard let normalizedURLString = Self.normalizedUserEnteredURLString(value) else {
            return false
        }

        lastRequestedURLString = normalizedURLString
        isShowingStartPage = false
        publishNavigationState()
        metadataDidChange(
            panelID,
            normalizedObservedTitle(),
            normalizedURLString
        )
        load(urlString: normalizedURLString)
        return true
    }

    @discardableResult
    func goBack() -> Bool {
        guard webView.canGoBack else {
            return false
        }
        webView.goBack()
        return true
    }

    @discardableResult
    func goForward() -> Bool {
        guard webView.canGoForward else {
            return false
        }
        webView.goForward()
        return true
    }

    @discardableResult
    func reloadOrStop() -> Bool {
        if webView.isLoading {
            webView.stopLoading()
            publishNavigationState()
            return true
        }

        guard let urlString = reportedCurrentURLString() else {
            return false
        }

        lastRequestedURLString = urlString
        load(urlString: urlString)
        return true
    }

    func automationState() -> BrowserPanelRuntimeAutomationState {
        BrowserPanelRuntimeAutomationState(
            lifecycleState: lifecycleState,
            pageZoom: webView.pageZoom
        )
    }

    private func synchronizeDisplayedContent(with webState: WebPanelState) {
        let desiredURLString = webState.restorableURL
        let currentURLString = reportedCurrentURLString()

        if let desiredURLString {
            if desiredURLString == currentURLString {
                lastRequestedURLString = desiredURLString
                isShowingStartPage = false
                publishNavigationState()
                return
            }
            guard desiredURLString != lastRequestedURLString else { return }
            lastRequestedURLString = desiredURLString
            isShowingStartPage = false
            publishNavigationState()
            load(urlString: desiredURLString)
            return
        }

        lastRequestedURLString = nil
        guard isShowingStartPage == false else { return }
        isShowingStartPage = true
        clearFavicon()
        publishNavigationState()
        webView.loadHTMLString(Self.defaultStartPageHTML, baseURL: nil)
    }

    private func load(urlString: String) {
        guard let url = URL(string: urlString) else {
            isShowingStartPage = false
            clearFavicon()
            publishNavigationState()
            webView.loadHTMLString(Self.invalidURLHTML(for: urlString), baseURL: nil)
            return
        }
        clearFavicon()
        if let fileLoad = Self.fileLoad(for: url) {
            webView.loadFileURL(
                fileLoad.fileURL,
                allowingReadAccessTo: fileLoad.readAccessURL
            )
            return
        }
        webView.load(URLRequest(url: url))
    }

    static func fileLoad(for url: URL) -> BrowserPanelFileLoad? {
        guard url.isFileURL else {
            return nil
        }

        let fileURL = url.standardizedFileURL
        return BrowserPanelFileLoad(
            fileURL: fileURL,
            readAccessURL: fileURL.deletingLastPathComponent()
        )
    }

    private func applyPageZoom(_ zoom: Double) {
        let nextZoom = WebPanelState.clampedBrowserPageZoom(zoom)
        currentPageZoom = nextZoom
        guard abs(webView.pageZoom - nextZoom) >= WebPanelState.browserPageZoomComparisonEpsilon else {
            return
        }
        webView.pageZoom = nextZoom
    }

    private func observeMetadataChanges() {
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.publishObservedMetadata()
                self?.publishNavigationState()
            }
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.publishObservedMetadata()
            }
        }
        canGoBackObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.publishNavigationState()
            }
        }
        canGoForwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.publishNavigationState()
            }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.publishNavigationState()
            }
        }
    }

    private func publishObservedMetadata() {
        metadataDidChange(
            panelID,
            normalizedObservedTitle(),
            reportedCurrentURLString()
        )
    }

    private func publishNavigationState() {
        let nextState = BrowserPanelNavigationState(
            displayedURLString: reportedCurrentURLString(),
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            isLoading: webView.isLoading
        )
        guard navigationState != nextState else { return }
        navigationState = nextState
    }

    private func normalizedObservedTitle() -> String? {
        WebPanelState.normalizedTitle(webView.title)
    }

    private func clearFavicon() {
        faviconRefreshTask?.cancel()
        faviconRefreshTask = nil
        pendingFaviconRequestID = nil
        if faviconImage != nil {
            faviconImage = nil
        }
    }

    private func refreshFavicon() {
        guard isShowingStartPage == false,
              let pageURL = webView.url else {
            clearFavicon()
            return
        }

        faviconRefreshTask?.cancel()
        let requestID = UUID()
        pendingFaviconRequestID = requestID
        faviconRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await self.firstAvailableFaviconImage(for: pageURL)
            guard Task.isCancelled == false,
                  self.pendingFaviconRequestID == requestID else {
                return
            }
            self.faviconRefreshTask = nil
            self.pendingFaviconRequestID = nil
            self.faviconImage = image
        }
    }

    private func firstAvailableFaviconImage(for pageURL: URL) async -> NSImage? {
        let candidateURLs = await faviconCandidateURLs(for: pageURL)
        for candidateURL in candidateURLs {
            guard Task.isCancelled == false else { return nil }
            if let image = await loadFaviconImage(from: candidateURL) {
                return image
            }
        }
        return nil
    }

    private func faviconCandidateURLs(for pageURL: URL) async -> [URL] {
        let references = await faviconLinkReferences()
        return Self.faviconCandidateURLs(linkReferences: references, pageURL: pageURL)
    }

    private func faviconLinkReferences() async -> [FaviconLinkReference] {
        let script = """
        (() => {
          const links = Array.from(document.querySelectorAll('link[rel]'));
          return links
            .map(link => ({
              rel: link.getAttribute('rel') || '',
              href: link.href || link.getAttribute('href') || ''
            }))
            .filter(link => link.href && link.rel.toLowerCase().includes('icon'));
        })();
        """
        guard let result = try? await webView.evaluateJavaScript(script) else {
            return []
        }
        if let references = result as? [[String: Any]] {
            return references.compactMap(Self.faviconLinkReference(from:))
        }
        if let references = result as? [[AnyHashable: Any]] {
            return references.compactMap(Self.faviconLinkReference(from:))
        }
        if let references = result as? [Any] {
            return references.compactMap { item in
                if let reference = item as? [String: Any] {
                    return Self.faviconLinkReference(from: reference)
                }
                if let reference = item as? [AnyHashable: Any] {
                    return Self.faviconLinkReference(from: reference)
                }
                return nil
            }
        }
        return []
    }

    private func loadFaviconImage(from url: URL) async -> NSImage? {
        do {
            let data: Data
            if url.isFileURL || url.scheme?.lowercased() == "data" {
                data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: url)
                }.value
            } else {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                let (responseData, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200 ..< 300).contains(httpResponse.statusCode) == false {
                    return nil
                }
                data = responseData
            }
            guard data.isEmpty == false else { return nil }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    private func reportedCurrentURLString() -> String? {
        if isShowingStartPage {
            return nil
        }

        if let observedURL = WebPanelState.normalizedCurrentURL(webView.url?.absoluteString) {
            return observedURL
        }

        return WebPanelState.normalizedCurrentURL(lastRequestedURLString)
    }

    private static func hostCandidate(from value: String) -> String {
        let scalars = value.unicodeScalars
        let endIndex = scalars.firstIndex(where: { "/?#".unicodeScalars.contains($0) }) ?? scalars.endIndex
        return String(scalars[..<endIndex])
    }

    private static func hasNumericPort(_ value: String) -> Bool {
        guard let colonIndex = value.lastIndex(of: ":") else {
            return false
        }

        let suffix = value[value.index(after: colonIndex)...]
        guard suffix.isEmpty == false else {
            return false
        }

        return suffix.allSatisfy(\.isNumber)
    }

    private static func hasExplicitScheme(_ value: String) -> Bool {
        guard let colonIndex = value.firstIndex(of: ":") else {
            return false
        }

        let scheme = value[..<colonIndex]
        guard scheme.isEmpty == false else {
            return false
        }

        guard let firstScalar = scheme.unicodeScalars.first, CharacterSet.letters.contains(firstScalar) else {
            return false
        }

        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-."))
        return scheme.unicodeScalars.allSatisfy(allowedScalars.contains)
    }

    private static func isLocalHost(_ value: String) -> Bool {
        value.caseInsensitiveCompare("localhost") == .orderedSame
    }

    private static func isBracketedIPv6Address(_ value: String) -> Bool {
        value.hasPrefix("[") && value.hasSuffix("]")
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return false
        }

        for octet in octets {
            guard let value = Int(octet), (0 ... 255).contains(value) else {
                return false
            }
        }

        return true
    }

    private enum FaviconLinkKind {
        case primary
        case appleTouch
        case mask
    }

    private static func faviconLinkKind(for rel: String) -> FaviconLinkKind? {
        let normalizedRel = rel.lowercased()
        if normalizedRel.contains("mask-icon") {
            return .mask
        }
        if normalizedRel.contains("apple-touch-icon") {
            return .appleTouch
        }
        if normalizedRel.contains("icon") {
            return .primary
        }
        return nil
    }

    private static func faviconLinkReference(
        from dictionary: [String: Any]
    ) -> FaviconLinkReference? {
        guard let href = dictionary["href"] as? String,
              let rel = dictionary["rel"] as? String else {
            return nil
        }
        return FaviconLinkReference(href: href, rel: rel)
    }

    private static func faviconLinkReference(
        from dictionary: [AnyHashable: Any]
    ) -> FaviconLinkReference? {
        guard let href = dictionary["href"] as? String,
              let rel = dictionary["rel"] as? String else {
            return nil
        }
        return FaviconLinkReference(href: href, rel: rel)
    }

    static var defaultStartPageHTML: String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Browser</title>
          <style>
            :root {
              color-scheme: dark;
              --bg: #0d1117;
              --panel: transparent;
              --text: #e8e4df;
              --muted: #6b5d52;
              --accent: #f5a623;
              --accent-dark: #0d0d0d;
              --accent-soft: rgba(245, 166, 35, 0.12);
              --toast-crust: #4a3425;
              --toast-bread: #6b4e38;
              --toast-highlight: #7d5c42;
              --toast-face: #2a1a10;
              --badge-bg: rgba(13, 13, 13, 0.12);
              --badge-text: rgba(13, 13, 13, 0.72);
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              min-height: 100vh;
              display: flex;
              align-items: center;
              justify-content: center;
              background:
                radial-gradient(circle at top left, var(--accent-soft), transparent 24rem),
                linear-gradient(180deg, #0f1319 0%, #0a0d12 100%);
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            }
            main {
              width: min(34rem, calc(100vw - 3rem));
              padding: 1.5rem 1.25rem 2rem;
              background: var(--panel);
              text-align: center;
            }
            .toast-wrap {
              position: relative;
              width: 120px;
              height: 120px;
              margin: 0 auto 28px;
            }
            .toast-glow {
              position: absolute;
              left: 50%;
              top: 50%;
              width: 112px;
              height: 112px;
              transform: translate(-50%, -44%);
              border-radius: 999px;
              background: radial-gradient(circle, rgba(245, 166, 35, 0.12) 0%, rgba(245, 166, 35, 0.04) 52%, transparent 72%);
              filter: blur(1px);
            }
            .toast {
              position: absolute;
              left: 50%;
              top: 50%;
              width: 56px;
              height: 48px;
              transform: translate(-50%, -24%);
              border-radius: 8px;
              background: var(--toast-crust);
            }
            .toast::before {
              content: "";
              position: absolute;
              inset: 4px;
              border-radius: 5px;
              background: var(--toast-bread);
            }
            .toast::after {
              content: "";
              position: absolute;
              left: 7px;
              right: 7px;
              top: 6px;
              height: 6px;
              border-radius: 3px;
              background: var(--toast-highlight);
            }
            .butter {
              position: absolute;
              left: 50%;
              top: 50%;
              width: 16px;
              height: 10px;
              transform: translate(-50%, -12px);
              border-radius: 2px;
              background: var(--accent);
              z-index: 2;
            }
            .eye {
              position: absolute;
              top: 63px;
              width: 5px;
              height: 2px;
              border-radius: 999px;
              background: var(--toast-face);
              z-index: 3;
            }
            .eye.left { left: 46px; }
            .eye.right { right: 46px; }
            .smile {
              position: absolute;
              left: 50%;
              top: 69px;
              width: 14px;
              height: 7px;
              transform: translateX(-50%);
              border: 2px solid var(--toast-face);
              border-top: 0;
              border-left-color: transparent;
              border-right-color: transparent;
              border-bottom-left-radius: 10px 8px;
              border-bottom-right-radius: 10px 8px;
              z-index: 3;
            }
            .steam {
              position: absolute;
              top: 22px;
              width: 12px;
              height: 18px;
              border: 2px solid rgba(107, 93, 82, 0.35);
              border-bottom: 0;
              border-left-color: transparent;
              border-right-color: transparent;
              border-radius: 999px;
            }
            .steam.left {
              left: 38px;
              transform: rotate(-12deg);
            }
            .steam.center {
              left: 54px;
              top: 18px;
              height: 20px;
            }
            .steam.right {
              right: 38px;
              transform: rotate(14deg);
            }
            h1 {
              margin: 0 0 0.55rem;
              font-size: 1.6rem;
              letter-spacing: 0.01em;
            }
            p {
              margin: 0;
              color: var(--muted);
              line-height: 1.5;
            }
            .quote {
              margin-bottom: 0.55rem;
              color: var(--text);
              font-size: 1.7rem;
              font-weight: 700;
              line-height: 1.1;
            }
            .body-copy {
              max-width: 28rem;
              margin: 0 auto;
            }
            .cta {
              display: inline-flex;
              align-items: center;
              gap: 12px;
              margin-top: 32px;
              padding: 14px 18px;
              border-radius: 999px;
              background: var(--accent);
              color: var(--accent-dark);
              text-decoration: none;
              box-shadow: 0 8px 14px rgba(245, 166, 35, 0.18);
            }
            .cta-label {
              font-size: 15px;
              font-weight: 600;
            }
            .cta-badge {
              display: inline-flex;
              align-items: center;
              justify-content: center;
              padding: 5px 8px;
              border-radius: 999px;
              background: var(--badge-bg);
              color: var(--badge-text);
              font-size: 12px;
              font-weight: 600;
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            }
            @media (max-width: 560px) {
              .quote {
                font-size: 1.45rem;
              }
            }
          </style>
        </head>
        <body>
          <main>
            <div class="toast-wrap" aria-hidden="true">
              <div class="toast-glow"></div>
              <div class="steam left"></div>
              <div class="steam center"></div>
              <div class="steam right"></div>
              <div class="toast"></div>
              <div class="butter"></div>
              <div class="eye left"></div>
              <div class="eye right"></div>
              <div class="smile"></div>
            </div>
            <h1 class="quote">Butter your workflow.</h1>
            <div class="cta" aria-hidden="true">
              <span class="cta-label">Focus Location</span>
              <span class="cta-badge">⌘L</span>
            </div>
          </main>
        </body>
        </html>
        """
    }

    private static func invalidURLHTML(for urlString: String) -> String {
        let escapedURL = urlString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Browser</title>
          <style>
            body {
              margin: 0;
              min-height: 100vh;
              display: flex;
              align-items: center;
              justify-content: center;
              background: #11151b;
              color: #eef3f8;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            }
            main {
              width: min(32rem, calc(100vw - 3rem));
              padding: 1.2rem;
              border: 1px solid #3a4554;
              border-radius: 16px;
              background: #181f28;
            }
            p {
              color: #aab7c6;
              line-height: 1.45;
            }
            code {
              color: #78d6ff;
            }
          </style>
        </head>
        <body>
          <main>
            <h1>Invalid Browser URL</h1>
            <p>Toastty could not load <code>\(escapedURL)</code>.</p>
          </main>
        </body>
        </html>
        """
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

    private func effectiveModifierFlags(for navigationAction: WKNavigationAction) -> NSEvent.ModifierFlags {
        let actionModifierFlags = navigationAction.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if actionModifierFlags.contains(.command) {
            return actionModifierFlags
        }

        // WKNavigationAction modifier flags can occasionally arrive empty for
        // link activations even though the triggering mouse event still has the
        // command key down. Fall back narrowly to the current AppKit event so
        // browser Cmd-click keeps working without broadening non-link flows.
        let currentEventModifierFlags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if navigationAction.navigationType == .linkActivated,
           currentEventModifierFlags.contains(.command) {
            return currentEventModifierFlags
        }

        return actionModifierFlags
    }

    @discardableResult
    private func openSecondaryURL(_ url: URL) -> Bool {
        openSecondaryURLForPanel(panelID, url)
    }

    private func installPopupCaptureController(configuration: WKWebViewConfiguration) -> WKWebView {
        // Some popup flows begin as nil/about:blank and only navigate to the
        // real destination after the new page has been created. Capture that
        // first usable URL offscreen, then hand it to Toastty's router.
        let controller = BrowserPopupCaptureController(
            configuration: configuration,
            openSecondaryURL: { [weak self] url in
                self?.openSecondaryURL(url) ?? false
            },
            cleanup: { [weak self] controllerID in
                self?.removePopupCaptureController(id: controllerID)
            }
        )
        popupCaptureControllers[controller.id] = controller
        return controller.webView
    }

    private func removePopupCaptureController(id: UUID) {
        guard let controller = popupCaptureControllers.removeValue(forKey: id) else {
            return
        }
        controller.invalidate()
    }
}

extension BrowserPanelRuntime: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didCommit _: WKNavigation!
    ) {
        guard webView === self.webView else {
            return
        }
        clearFavicon()
        publishNavigationState()
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        _ = navigation
        guard webView === self.webView else {
            return
        }
        if let observedURL = WebPanelState.normalizedCurrentURL(webView.url?.absoluteString),
           observedURL.caseInsensitiveCompare("about:blank") != .orderedSame {
            isShowingStartPage = false
        }
        applyPageZoom(currentPageZoom)
        publishObservedMetadata()
        publishNavigationState()
        refreshFavicon()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        _ = navigation
        _ = error
        guard webView === self.webView else {
            return
        }
        clearFavicon()
        publishObservedMetadata()
        publishNavigationState()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        _ = navigation
        _ = error
        guard webView === self.webView else {
            return
        }
        clearFavicon()
        publishObservedMetadata()
        publishNavigationState()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard webView === self.webView else {
            decisionHandler(.allow)
            return
        }

        switch BrowserLinkRoutingRules.navigationPolicyDecision(
            url: navigationAction.request.url,
            navigationType: navigationAction.navigationType,
            modifierFlags: effectiveModifierFlags(for: navigationAction),
            targetFrameIsNil: navigationAction.targetFrame == nil
        ) {
        case .allow:
            decisionHandler(.allow)
        case .openSecondary(let url):
            _ = openSecondaryURL(url)
            decisionHandler(.cancel)
        }
    }
}

extension BrowserPanelRuntime: WKUIDelegate {
    func webView(
        _: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        _ = windowFeatures
        guard navigationAction.targetFrame == nil else {
            return nil
        }

        switch BrowserLinkRoutingRules.popupRoutingDecision(
            requestURL: navigationAction.request.url
        ) {
        case .openSecondary(let url):
            _ = openSecondaryURL(url)
            return nil
        case .awaitCapturedURL:
            return installPopupCaptureController(configuration: configuration)
        }
    }
}
