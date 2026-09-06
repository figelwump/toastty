import RemoteProtocol
import SwiftUI
import WebKit

/// The trusted shell is the only frame allowed to communicate with native code.
/// Generated Scratchpad content keeps its separate opaque-origin iframe.
struct ToasttyBundledPreviewWebView: UIViewRepresentable {
    enum Content: Equatable {
        case document(RemotePreviewDocument)
        case scratchpad(RemotePreviewScratchpad)

        func requiresBootstrap(comparedTo previous: Content) -> Bool {
            if case .scratchpad(let current) = self, case .scratchpad(let prior) = previous {
                return current.documentID != prior.documentID || current.revision != prior.revision
            }
            return self != previous
        }
        var directory: String {
            switch self {
            case .document: "local-document-panel"
            case .scratchpad: "scratchpad-panel"
            }
        }
        var bridgeName: String {
            switch self {
            case .document: "toasttyLocalDocumentPanel"
            case .scratchpad: "toasttyScratchpadPanel"
            }
        }
    }
    let content: Content
    let fitRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(content: content) }

    func makeUIView(context: Context) -> ToasttyPreviewViewport {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if case .scratchpad = content {
            // The outer scroll view owns canvas zoom. Otherwise WebKit can
            // magnify inside the already-fitted frame and Fit cannot undo it.
            configuration.ignoresViewportScaleLimits = false
            configuration.userContentController.addUserScript(WKUserScript(
                source: """
                document.querySelector('meta[name="viewport"]')?.setAttribute('content',
                  'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no');
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        configuration.userContentController.add(context.coordinator, name: content.bridgeName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.accessibilityIdentifier = "toastty-preview-web-content"
        let viewport = ToasttyPreviewViewport(webView: webView, usesCanvas: content.directory == "scratchpad-panel")
        context.coordinator.viewport = viewport
        if let entry = Bundle.main.url(forResource: "index", withExtension: "html",
                                        subdirectory: content.directory) {
            context.coordinator.entryURL = entry
            webView.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
        }
        return viewport
    }

    func updateUIView(_ viewport: ToasttyPreviewViewport, context: Context) {
        let requiresBootstrap = content.requiresBootstrap(comparedTo: context.coordinator.content)
        context.coordinator.content = content
        if requiresBootstrap { context.coordinator.deliverBootstrap() }
        if context.coordinator.fitRequest != fitRequest {
            context.coordinator.fitRequest = fitRequest
            viewport.fit()
        }
    }

    static func dismantleUIView(_ viewport: ToasttyPreviewViewport, coordinator: Coordinator) {
        viewport.webView.stopLoading()
        viewport.webView.configuration.userContentController.removeScriptMessageHandler(forName: coordinator.content.bridgeName)
        viewport.webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var content: Content
        var fitRequest = 0
        weak var viewport: ToasttyPreviewViewport?
        var entryURL: URL?
        private var bridgeReady = false
        init(content: Content) { self.content = content }

        static func acceptsReadOnlyEvent(_ type: String, isMainFrame: Bool) -> Bool {
            isMainFrame && ["bridgeReady", "renderReady", "contentSize", "searchControllerReady",
                            "searchControllerUnavailable"].contains(type)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == content.bridgeName,
                  let body = message.body as? [String: Any], let type = body["type"] as? String,
                  Self.acceptsReadOnlyEvent(type, isMainFrame: message.frameInfo.isMainFrame) else { return }
            switch type {
            case "bridgeReady":
                bridgeReady = true
                deliverBootstrap()
            case "contentSize":
                guard case .scratchpad(let scratchpad) = content,
                      body["revision"] as? Int == scratchpad.revision,
                      let width = body["width"] as? Double, let height = body["height"] as? Double,
                      width.isFinite, height.isFinite,
                      (320...16_384).contains(width), (320...16_384).contains(height) else { return }
                viewport?.setCanvasSize(CGSize(width: width, height: height))
            default: break
            }
        }

        func deliverBootstrap() {
            guard bridgeReady, let webView = viewport?.webView else { return }
            let bootstrap: [String: Any]
            let receiver: String
            switch content {
            case .document(let document):
                receiver = "ToasttyLocalDocumentPanel"
                bootstrap = [
                    "contractVersion": 7, "filePath": document.sourcePath,
                    "displayName": document.title, "format": document.format,
                    "syntaxLanguage": document.language as Any? ?? NSNull(),
                    "formatLabel": document.formatLabel, "shouldHighlight": document.highlight,
                    "highlightState": document.highlightState, "content": document.content,
                    "contentRevision": 1, "isEditing": false, "isDirty": false,
                    "hasExternalConflict": false, "isSaving": false,
                    "saveErrorMessage": NSNull(), "theme": "dark", "textScale": 1,
                    "presentation": "mobileReadOnly"
                ]
            case .scratchpad(let scratchpad):
                receiver = "ToasttyScratchpadPanel"
                bootstrap = [
                    "contractVersion": 1, "documentID": scratchpad.documentID.uuidString,
                    "displayName": scratchpad.title, "revision": scratchpad.revision,
                    "contentHTML": scratchpad.html, "missingDocument": false,
                    "sessionLinked": true, "message": NSNull(), "theme": "dark", "mobileViewport": true
                ]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: bootstrap),
                  let json = String(data: data, encoding: .utf8) else { return }
            var script = "window.\(receiver)?.receiveBootstrap(\(json));"
            if case .document(let document) = content, let line = document.line, line > 0 {
                script += "window.ToasttyLocalDocumentPanel?.revealLine(\(line));"
            }
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // WebKit may install its pinch recognizer after view construction.
            viewport?.prepareCanvasGestures()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(url.absoluteString == "about:srcdoc" || url.absoluteString == "about:blank" ? .allow : .cancel)
            } else {
                decisionHandler(url == entryURL ? .allow : .cancel)
            }
        }
    }
}

/// Zooms the actual WebKit view, so generated buttons and inputs retain native
/// hit testing. There is no gesture overlay over the sandboxed iframe.
@MainActor
final class ToasttyPreviewViewport: UIScrollView, UIScrollViewDelegate {
    let webView: WKWebView
    private let usesCanvas: Bool
    private var canvasSize = CGSize(width: 1024, height: 900)
    private var lastBoundsSize = CGSize.zero
    private var hasFitted = false
    private var userChangedZoom = false

    init(webView: WKWebView, usesCanvas: Bool) {
        self.webView = webView
        self.usesCanvas = usesCanvas
        super.init(frame: .zero)
        addSubview(webView)
        delegate = self
        backgroundColor = .clear
        if usesCanvas {
            maximumZoomScale = 3
            bouncesZoom = true
            prepareCanvasGestures()
        } else {
            isScrollEnabled = false
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if !usesCanvas {
            webView.frame = bounds
        } else if lastBoundsSize != bounds.size {
            lastBoundsSize = bounds.size
            fit()
        }
    }

    func setCanvasSize(_ size: CGSize) {
        guard usesCanvas, canvasSize != size else { return }
        canvasSize = size
        let scale = zoomScale
        setZoomScale(1, animated: false)
        webView.frame = CGRect(origin: .zero, size: canvasSize)
        contentSize = canvasSize
        if !userChangedZoom { fit() }
        else { setZoomScale(scale, animated: false) }
    }

    func prepareCanvasGestures() {
        guard usesCanvas else { return }
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
    }

    func fit() {
        guard usesCanvas, bounds.width > 0, bounds.height > 0 else { return }
        userChangedZoom = false
        // Explicit Fit also clears any WebKit focus zoom from an input field.
        webView.scrollView.setZoomScale(1, animated: false)
        setZoomScale(1, animated: false)
        webView.frame = CGRect(origin: .zero, size: canvasSize)
        contentSize = canvasSize
        minimumZoomScale = min(bounds.width / canvasSize.width, bounds.height / canvasSize.height)
        setZoomScale(minimumZoomScale, animated: false)
        contentOffset = .zero
        hasFitted = true
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { usesCanvas ? webView : nil }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        if hasFitted { userChangedZoom = true }
    }
}
