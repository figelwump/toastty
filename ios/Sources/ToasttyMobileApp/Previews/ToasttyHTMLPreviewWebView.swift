import RemoteProtocol
import SwiftUI
import WebKit

/// A fixed policy for local files, deliberately separate from an ordinary web
/// browser. Only this scheme handler can supply external page resources.
enum ToasttyHTMLPreviewPolicy {
    static let scheme = "toastty-preview"
    static let csp = [
        "default-src 'none'", "script-src 'unsafe-inline' toastty-preview:",
        "style-src 'unsafe-inline' toastty-preview:", "img-src toastty-preview: data: blob:",
        "font-src toastty-preview: data: blob:", "media-src toastty-preview: data: blob:",
        "connect-src 'none'", "frame-src 'none'", "worker-src 'none'", "object-src 'none'",
        "base-uri 'none'", "form-action 'none'"
    ].joined(separator: "; ")
    // This script runs in an isolated world: page scripts share its DOM but
    // cannot read or forge its one-shot trusted-link record. No native bridge
    // is registered in either world.
    static let trustedLinkScript = """
    (() => {
      let destination = null;
      window.addEventListener('click', event => {
        destination = null;
        if (!event.isTrusted) return;
        const anchor = event.composedPath().find(node => node instanceof HTMLAnchorElement);
        if (anchor) destination = anchor.href;
      }, true);
      window.ToasttyConsumeTrustedLink = url => {
        const allowed = destination === url;
        destination = null;
        return allowed;
      };
    })();
    """

    static let maximumResourceBytes = 5 * 1024 * 1024

    static func relativePath(for url: URL, host: String) -> String? {
        guard url.scheme == scheme, url.host == host, url.user == nil, url.password == nil,
              url.port == nil else { return nil }
        let components = url.path(percentEncoded: true).split(separator: "/")
        guard !components.isEmpty else { return nil }
        var decoded: [String] = []
        for component in components {
            guard let value = String(component).removingPercentEncoding,
                  value != ".", value != "..", !value.contains("/"), !value.contains("\\"),
                  !value.contains("\0") else { return nil }
            decoded.append(value)
        }
        return decoded.joined(separator: "/")
    }

    static func permitsNavigation(_ url: URL, host: String, explicitLink: Bool) -> Bool {
        relativePath(for: url, host: host) != nil ||
            (explicitLink && ToasttyPreviewURLPolicy.isReachableWebURL(url))
    }
}

struct ToasttyHTMLPreviewWebView: UIViewRepresentable {
    let document: RemotePreviewHTML
    let target: RemotePreviewTarget
    let resource: @Sendable (RemoteHTMLResourceRequest) async throws -> RemoteHTMLResourceResponse

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, target: target, resource: resource)
    }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.loader, forURLScheme: ToasttyHTMLPreviewPolicy.scheme)
        configuration.userContentController.addUserScript(WKUserScript(
            source: ToasttyHTMLPreviewPolicy.trustedLinkScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .defaultClient))
        // No script-message handlers, cookies, or gateway URL enter this page.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.accessibilityIdentifier = "toastty-html-preview-content"
        webView.load(URLRequest(url: context.coordinator.loader.entryURL))
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {}
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        coordinator.loader.cancelAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let loader: ToasttyHTMLResourceLoader
        init(document: RemotePreviewHTML, target: RemotePreviewTarget,
             resource: @escaping @Sendable (RemoteHTMLResourceRequest) async throws -> RemoteHTMLResourceResponse) {
            loader = ToasttyHTMLResourceLoader(document: document, target: target, resource: resource)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if ToasttyHTMLPreviewPolicy.relativePath(for: url, host: loader.host) != nil {
                decisionHandler(navigationAction.targetFrame?.isMainFrame == false ? .cancel : .allow)
                return
            }
            // Script-driven navigation and redirects cannot launch another app.
            if navigationAction.navigationType == .linkActivated,
               ToasttyPreviewURLPolicy.isReachableWebURL(url) {
                openTrustedExternalLink(url, in: webView)
            }
            decisionHandler(.cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else { return nil }
            if ToasttyHTMLPreviewPolicy.relativePath(for: url, host: loader.host) != nil {
                webView.load(URLRequest(url: url))
            } else if ToasttyPreviewURLPolicy.isReachableWebURL(url) {
                openTrustedExternalLink(url, in: webView)
            }
            return nil
        }

        private func openTrustedExternalLink(_ url: URL, in webView: WKWebView) {
            guard let data = try? JSONEncoder().encode(url.absoluteString),
                  let literal = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.ToasttyConsumeTrustedLink?.(\(literal)) === true",
                                       in: nil, in: .defaultClient) { result in
                guard case .success(let value) = result, value as? Bool == true else { return }
                UIApplication.shared.open(url)
            }
        }

    }
}

@MainActor
final class ToasttyHTMLResourceLoader: NSObject, WKURLSchemeHandler {
    let host = UUID().uuidString.lowercased()
    let document: RemotePreviewHTML
    let target: RemotePreviewTarget
    let resource: @Sendable (RemoteHTMLResourceRequest) async throws -> RemoteHTMLResourceResponse
    private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
    var entryURL: URL {
        var components = URLComponents()
        components.scheme = ToasttyHTMLPreviewPolicy.scheme
        components.host = host
        components.path = "/" + (document.sourcePath as NSString).lastPathComponent
        return components.url!
    }

    init(document: RemotePreviewHTML, target: RemotePreviewTarget,
         resource: @escaping @Sendable (RemoteHTMLResourceRequest) async throws -> RemoteHTMLResourceResponse) {
        self.document = document
        self.target = target
        self.resource = resource
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard pending.count < 32,
              let url = urlSchemeTask.request.url,
              let path = ToasttyHTMLPreviewPolicy.relativePath(for: url, host: host) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let entryPath = (document.sourcePath as NSString).lastPathComponent
        pending[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { pending[id] = nil }
            do {
                try Task.checkCancellation()
                let data: Data
                let mimeType: String
                if path == entryPath {
                    data = Data(document.html.utf8)
                    mimeType = "text/html; charset=utf-8"
                } else {
                    let response = try await resource(RemoteHTMLResourceRequest(
                        target: target, expectedSourcePath: document.sourcePath, relativePath: path))
                    guard let bytes = response.data, let mime = response.mimeType else {
                        throw URLError(.badServerResponse)
                    }
                    data = bytes
                    mimeType = mime
                }
                try Task.checkCancellation()
                guard data.count <= ToasttyHTMLPreviewPolicy.maximumResourceBytes,
                      pending[id] != nil,
                      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": mimeType, "Content-Security-Policy": ToasttyHTMLPreviewPolicy.csp,
                                       "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
                                       "Referrer-Policy": "no-referrer"]) else { throw URLError(.badServerResponse) }
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, pending[id] != nil else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        pending.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
    func cancelAll() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }
}

struct ToasttyBrowserPreview: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) { uiView.stopLoading() }
}
