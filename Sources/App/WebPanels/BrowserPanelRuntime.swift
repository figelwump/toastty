import AppKit
import CoreState
import Foundation
import WebKit

@MainActor
final class BrowserPanelRuntime: NSObject, PanelHostLifecycleControlling {
    private let panelID: UUID
    private let metadataDidChange: @MainActor (UUID, String?, String?) -> Void
    private let webView: WKWebView
    private var urlObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private weak var activeSourceContainer: NSView?
    private var activeAttachment: PanelHostAttachmentToken?
    private var pendingDetachAttachment: PanelHostAttachmentToken?
    private var pendingDetachTask: Task<Void, Never>?
    private var lastRequestedURLString: String?
    private var isShowingStartPage = false

    init(
        panelID: UUID,
        metadataDidChange: @escaping @MainActor (UUID, String?, String?) -> Void
    ) {
        self.panelID = panelID
        self.metadataDidChange = metadataDidChange
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeMetadataChanges()
    }

    deinit {
        pendingDetachTask?.cancel()
        urlObservation?.invalidate()
        titleObservation?.invalidate()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
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

    func update(
        webState: WebPanelState,
        sourceContainer: NSView,
        attachment: PanelHostAttachmentToken
    ) {
        if let activeAttachment,
           attachment.generation < activeAttachment.generation {
            return
        }

        if activeSourceContainer !== sourceContainer || webView.superview !== sourceContainer {
            attachHost(to: sourceContainer, attachment: attachment)
        }

        synchronizeDisplayedContent(with: webState)
    }

    private func synchronizeDisplayedContent(with webState: WebPanelState) {
        let desiredURLString = WebPanelState.normalizedURL(webState.url)
        let currentURLString = normalizedObservedURLString()

        if let desiredURLString {
            if desiredURLString == currentURLString {
                lastRequestedURLString = desiredURLString
                isShowingStartPage = false
                return
            }
            guard desiredURLString != lastRequestedURLString else { return }
            lastRequestedURLString = desiredURLString
            isShowingStartPage = false
            load(urlString: desiredURLString)
            return
        }

        lastRequestedURLString = nil
        guard isShowingStartPage == false else { return }
        isShowingStartPage = true
        webView.loadHTMLString(Self.defaultStartPageHTML, baseURL: nil)
    }

    private func load(urlString: String) {
        guard let url = URL(string: urlString) else {
            isShowingStartPage = false
            webView.loadHTMLString(Self.invalidURLHTML(for: urlString), baseURL: nil)
            return
        }
        webView.load(URLRequest(url: url))
    }

    private func observeMetadataChanges() {
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.publishObservedMetadata()
            }
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.publishObservedMetadata()
            }
        }
    }

    private func publishObservedMetadata() {
        metadataDidChange(
            panelID,
            normalizedObservedTitle(),
            normalizedObservedURLString()
        )
    }

    private func normalizedObservedTitle() -> String? {
        WebPanelState.normalizedTitle(webView.title)
    }

    private func normalizedObservedURLString() -> String? {
        WebPanelState.normalizedURL(webView.url?.absoluteString)
    }

    private static var defaultStartPageHTML: String {
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
              --bg: #0f1319;
              --panel: #161d26;
              --border: #2b3644;
              --text: #eef3f8;
              --muted: #9fb0c3;
              --accent: #78d6ff;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              min-height: 100vh;
              display: flex;
              align-items: center;
              justify-content: center;
              background:
                radial-gradient(circle at top left, rgba(120, 214, 255, 0.18), transparent 28rem),
                linear-gradient(180deg, #0f1319 0%, #0a0d12 100%);
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            }
            main {
              width: min(34rem, calc(100vw - 3rem));
              padding: 1.4rem;
              border: 1px solid var(--border);
              border-radius: 18px;
              background: rgba(22, 29, 38, 0.9);
              box-shadow: 0 20px 80px rgba(0, 0, 0, 0.32);
            }
            h1 {
              margin: 0 0 0.5rem;
              font-size: 1.15rem;
              letter-spacing: 0.02em;
            }
            p {
              margin: 0;
              color: var(--muted);
              line-height: 1.5;
            }
            a {
              color: var(--accent);
            }
            .links {
              margin-top: 1rem;
              display: flex;
              gap: 0.85rem;
              flex-wrap: wrap;
            }
          </style>
        </head>
        <body>
          <main>
            <h1>Browser Panel</h1>
            <p>The browser runtime is live. Use automation with <code>panel.create.browser</code> and a URL to open a specific page, or click a link below.</p>
            <div class="links">
              <a href="https://example.com">Open example.com</a>
              <a href="https://developer.apple.com/documentation/webkit">Open WebKit docs</a>
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
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        _ = navigation
        if WebPanelState.normalizedURL(webView.url?.absoluteString) != nil {
            isShowingStartPage = false
        }
        publishObservedMetadata()
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
