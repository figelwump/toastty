import AppKit
import Combine
import CoreState
import Foundation
import WebKit

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

private final class FocusAwareWKWebView: WKWebView {
    var interactionDidRequestFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        interactionDidRequestFocus?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        interactionDidRequestFocus?()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        interactionDidRequestFocus?()
        super.otherMouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        interactionDidRequestFocus?()
        return super.becomeFirstResponder()
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

    init(
        panelID: UUID,
        metadataDidChange: @escaping @MainActor (UUID, String?, String?) -> Void,
        interactionDidRequestFocus: @escaping @MainActor (UUID) -> Void
    ) {
        self.panelID = panelID
        self.metadataDidChange = metadataDidChange
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let webView = FocusAwareWKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
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
        webView.interactionDidRequestFocus = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
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
        synchronizeDisplayedContent(with: webState)
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
        webView.load(URLRequest(url: url))
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
              --panel: rgba(19, 25, 34, 0.92);
              --panel-strong: rgba(24, 31, 42, 0.98);
              --border: #2b3644;
              --text: #eef3f8;
              --muted: #9fb0c3;
              --accent: #f3a43b;
              --accent-soft: rgba(243, 164, 59, 0.16);
              --secondary-accent: rgba(120, 214, 255, 0.14);
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
                radial-gradient(circle at top right, var(--secondary-accent), transparent 24rem),
                linear-gradient(180deg, #0f1319 0%, #0a0d12 100%);
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            }
            main {
              width: min(36rem, calc(100vw - 3rem));
              padding: 1.5rem;
              border: 1px solid var(--border);
              border-radius: 18px;
              background: var(--panel);
              box-shadow: 0 20px 80px rgba(0, 0, 0, 0.32);
            }
            .eyebrow {
              display: inline-flex;
              align-items: center;
              gap: 0.45rem;
              margin-bottom: 0.95rem;
              padding: 0.35rem 0.65rem;
              border-radius: 999px;
              border: 1px solid rgba(243, 164, 59, 0.24);
              background: rgba(243, 164, 59, 0.08);
              color: #ffd8a6;
              font-size: 0.76rem;
              font-weight: 600;
              letter-spacing: 0.08em;
              text-transform: uppercase;
            }
            .eyebrow-dot {
              width: 0.45rem;
              height: 0.45rem;
              border-radius: 999px;
              background: var(--accent);
              box-shadow: 0 0 18px rgba(243, 164, 59, 0.45);
            }
            h1 {
              margin: 0 0 0.55rem;
              font-size: 1.55rem;
              letter-spacing: 0.01em;
            }
            p {
              margin: 0;
              color: var(--muted);
              line-height: 1.5;
            }
            .shortcut-grid {
              margin-top: 1.1rem;
              display: grid;
              grid-template-columns: repeat(2, minmax(0, 1fr));
              gap: 0.7rem;
            }
            .shortcut-card {
              padding: 0.85rem 0.95rem;
              border-radius: 14px;
              border: 1px solid rgba(255, 255, 255, 0.06);
              background: var(--panel-strong);
            }
            .shortcut-key {
              display: inline-flex;
              margin-bottom: 0.35rem;
              padding: 0.24rem 0.5rem;
              border-radius: 999px;
              background: rgba(255, 255, 255, 0.06);
              color: var(--text);
              font-size: 0.72rem;
              font-weight: 600;
              letter-spacing: 0.05em;
            }
            .shortcut-title {
              display: block;
              margin-bottom: 0.2rem;
              color: var(--text);
              font-size: 0.95rem;
              font-weight: 600;
            }
            .shortcut-copy {
              color: var(--muted);
              font-size: 0.84rem;
              line-height: 1.45;
            }
            @media (max-width: 720px) {
              .shortcut-grid {
                grid-template-columns: 1fr;
              }
            }
          </style>
        </head>
        <body>
          <main>
            <div class="eyebrow">
              <span class="eyebrow-dot"></span>
              Toastty Browser
            </div>
            <h1>Open a page</h1>
            <p>Use the location field above to load a URL. New browser panels start here until you navigate somewhere.</p>
            <div class="shortcut-grid">
              <section class="shortcut-card">
                <span class="shortcut-key">Cmd+L</span>
                <span class="shortcut-title">Focus the location field</span>
                <div class="shortcut-copy">Jump to the address bar without leaving the keyboard.</div>
              </section>
              <section class="shortcut-card">
                <span class="shortcut-key">Cmd+R</span>
                <span class="shortcut-title">Reload or stop</span>
                <div class="shortcut-copy">Refresh the current page, or stop a load that is still in progress.</div>
              </section>
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
}

extension BrowserPanelRuntime: WKNavigationDelegate {
    func webView(
        _: WKWebView,
        didCommit _: WKNavigation!
    ) {
        clearFavicon()
        publishNavigationState()
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        _ = navigation
        if let observedURL = WebPanelState.normalizedCurrentURL(webView.url?.absoluteString),
           observedURL.caseInsensitiveCompare("about:blank") != .orderedSame {
            isShowingStartPage = false
        }
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
        clearFavicon()
        publishObservedMetadata()
        publishNavigationState()
    }
}

extension BrowserPanelRuntime: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        _ = configuration
        _ = windowFeatures
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else {
            return nil
        }
        webView.load(URLRequest(url: url))
        return nil
    }
}
