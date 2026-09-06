import RemoteProtocol
import WebKit
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class ToasttyPreviewTests: XCTestCase {
    func testNavigationDelegatesImplementWebKitPolicySelector() {
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        let document = RemotePreviewDocument(title: "Source", sourcePath: "/project/a.md", content: "text",
                                              format: "markdown", revision: "1")
        let source = ToasttyBundledPreviewWebView.Coordinator(content: .document(document))
        let html = ToasttyHTMLPreviewWebView.Coordinator(
            document: .init(title: "Page", sourcePath: "/project/index.html", html: "", revision: "1"),
            target: .panel(workspaceID: UUID(), panelID: UUID()), resource: { _ in throw RemotePreviewError.denied })
        XCTAssertTrue(source.responds(to: selector))
        XCTAssertTrue(html.responds(to: selector))
    }

    func testStoppedHTMLResourceTaskNeverDeliversLateCallbacks() async throws {
        let started = expectation(description: "Asset fetch started")
        let cancelled = expectation(description: "Asset fetch cancelled")
        let loader = ToasttyHTMLResourceLoader(
            document: .init(title: "Page", sourcePath: "/project/index.html", html: "", revision: "1"),
            target: .panel(workspaceID: UUID(), panelID: UUID()), resource: { _ in
                started.fulfill()
                defer { cancelled.fulfill() }
                try await Task.sleep(for: .seconds(30))
                return .init(mimeType: "text/css", data: Data())
            })
        let webView = WKWebView()
        let task = PreviewSchemeTask(request: URLRequest(url: loader.entryURL.deletingLastPathComponent().appendingPathComponent("style.css")))
        loader.webView(webView, start: task)
        await fulfillment(of: [started], timeout: 5)
        loader.webView(webView, stop: task)
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertTrue(task.callbacks.isEmpty)
    }

    func testUnsupportedFileAndOlderHostHaveDifferentRecoveryGuidance() {
        XCTAssertFalse(ToasttyPreviewSheet.message(for: RemotePreviewError.unsupported).contains("Update"))
        XCTAssertTrue(ToasttyPreviewSheet.message(for: GatewayFailure.operationCompatibility(
            .missingCapability(.localFilePreview))).contains("Update Toastty on your Mac"))
    }

    func testLocalSemanticLinkRoutesPreserveLineReferencesAndExternalLinks() throws {
        for reference in ["docs/mobile-preview.md:12", "docs/mobile-preview.md#L12", "README.md:12", "file.swift:12:3",
                          "/project/a.swift:8", "file:///project/a.swift#L8", "docs/a%20b.md"] {
            let url = try XCTUnwrap(URL(string: reference))
            XCTAssertNotNil(ToasttyPreviewURLPolicy.localFileReference(url), reference)
        }
        XCTAssertEqual(ToasttyPreviewURLPolicy.localFileReference(try XCTUnwrap(URL(string: "docs/a%20b.md#L12"))),
                       "docs/a b.md#L12")
        XCTAssertEqual(ToasttyPreviewURLPolicy.localFileReference(try XCTUnwrap(URL(string: "file:///project/a%2520b.md#L12"))),
                       "/project/a%20b.md#L12")
        for reference in ["https://example.com/a.md", "mailto:someone@example.com", "javascript:alert(1)", "#heading"] {
            XCTAssertNil(ToasttyPreviewURLPolicy.localFileReference(try XCTUnwrap(URL(string: reference))), reference)
        }
    }

    func testReadOnlyBridgeRejectsMutationAndEverySubframeEvent() {
        for event in ["enterEdit", "save", "cancelEdit", "draftDidChange", "overwriteAfterConflict", "openInDefaultApp"] {
            XCTAssertFalse(ToasttyBundledPreviewWebView.Coordinator.acceptsReadOnlyEvent(event, isMainFrame: true))
        }
        for event in ["bridgeReady", "renderReady", "contentSize"] {
            XCTAssertTrue(ToasttyBundledPreviewWebView.Coordinator.acceptsReadOnlyEvent(event, isMainFrame: true))
            XCTAssertFalse(ToasttyBundledPreviewWebView.Coordinator.acceptsReadOnlyEvent(event, isMainFrame: false))
        }
    }

    func testCanvasFitRestoresOuterViewportScaleWithoutResettingOnOrdinaryLayout() {
        let webView = WKWebView()
        let viewport = ToasttyPreviewViewport(webView: webView, usesCanvas: true)
        viewport.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        viewport.layoutIfNeeded()
        let fittedScale = viewport.zoomScale
        viewport.setZoomScale(fittedScale * 2, animated: false)
        viewport.setNeedsLayout()
        viewport.layoutIfNeeded()
        XCTAssertEqual(viewport.zoomScale, fittedScale * 2, accuracy: 0.001)
        viewport.fit()
        XCTAssertEqual(viewport.zoomScale, fittedScale, accuracy: 0.001)
        XCTAssertEqual(webView.scrollView.minimumZoomScale, 1)
        XCTAssertEqual(webView.scrollView.maximumZoomScale, 1)
    }

    func testSameScratchpadRevisionPreservesInteractiveState() {
        let id = UUID()
        let first = ToasttyBundledPreviewWebView.Content.scratchpad(
            .init(documentID: id, title: "First title", html: "<button>Count</button>", revision: 1))
        let renamed = ToasttyBundledPreviewWebView.Content.scratchpad(
            .init(documentID: id, title: "Renamed", html: "<button>Count</button>", revision: 1))
        let updated = ToasttyBundledPreviewWebView.Content.scratchpad(
            .init(documentID: id, title: "Renamed", html: "<button>New</button>", revision: 2))
        XCTAssertFalse(renamed.requiresBootstrap(comparedTo: first))
        XCTAssertTrue(updated.requiresBootstrap(comparedTo: first))
    }

    func testPanelOnlyWorkspaceSurvivesRankingAndEverySessionFilter() throws {
        let source = try XCTUnwrap(ToasttyMobileFixture.home.workspaces.first { !$0.panels.isEmpty && $0.conversations.isEmpty })
        let snapshot = MobileHomeSnapshot(hostName: "Mac", workspaces: [source])
        for filter in ToasttyWorkspaceSessionFilter.allCases {
            let result = filter.workspaces(from: snapshot.rankedWorkspaces)
            XCTAssertEqual(result.first?.id, source.id)
            XCTAssertEqual(result.first?.panels, source.panels)
            XCTAssertEqual(result.first?.conversations.count, 0)
        }
    }

    func testHTMLResourcePathsStayInThisPreviewAndDecodeExactlyOnce() throws {
        let host = "preview"
        let good = try XCTUnwrap(URL(string: "toastty-preview://preview/styles/a%20b.css?v=2"))
        XCTAssertEqual(ToasttyHTMLPreviewPolicy.relativePath(for: good, host: host), "styles/a b.css")
        for value in ["toastty-preview://other/x.css", "https://preview/x.css",
                      "toastty-preview://preview/%2e%2e/secret", "toastty-preview://preview/a%2fb.css",
                      "toastty-preview://preview/a%5cb.css", "toastty-preview://preview/a%00b.css"] {
            XCTAssertNil(ToasttyHTMLPreviewPolicy.relativePath(for: try XCTUnwrap(URL(string: value)), host: host), value)
        }
        let remote = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertFalse(ToasttyHTMLPreviewPolicy.permitsNavigation(remote, host: host, explicitLink: false))
        XCTAssertTrue(ToasttyHTMLPreviewPolicy.permitsNavigation(remote, host: host, explicitLink: true))
        for value in ["http://localhost:3000", "http://127.0.0.1", "http://[::1]", "file:///x.html"] {
            XCTAssertFalse(ToasttyPreviewURLPolicy.isReachableWebURL(try XCTUnwrap(URL(string: value))))
        }
    }

    func testHTMLResponseCSPAllowsLocalInteractionsAndBlocksNetworkInWebKit() async throws {
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width">
        <script>
        window.violations=[];
        document.addEventListener('securitypolicyviolation', e => window.violations.push(e.effectiveDirective));
        window.inlineRan=true;
        fetch('https://toastty-preview-test.invalid/blocked').catch(() => window.fetchBlocked=true);
        </script><script src="scripts/test.js"></script><link rel="stylesheet" href="styles/test.css"></head>
        <body><button id="count" onclick="this.textContent='Count: 1'">Count: 0</button>
        <img src="https://toastty-preview-test.invalid/image.png">
        <iframe src="https://toastty-preview-test.invalid/frame"></iframe></body></html>
        """
        let document = RemotePreviewHTML(title: "Policy", sourcePath: "/project/index.html", html: html, revision: "1")
        let loader = ToasttyHTMLResourceLoader(document: document,
            target: .panel(workspaceID: UUID(), panelID: UUID()), resource: { request in
                switch request.relativePath {
                case "scripts/test.js":
                    .init(mimeType: "text/javascript", data: Data("window.localRan=true;".utf8))
                case "styles/test.css":
                    .init(mimeType: "text/css", data: Data("body { color: rgb(1, 2, 3); }".utf8))
                default: throw RemotePreviewError.denied
                }
            })
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(loader, forURLScheme: ToasttyHTMLPreviewPolicy.scheme)
        config.userContentController.addUserScript(WKUserScript(
            source: ToasttyHTMLPreviewPolicy.trustedLinkScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .defaultClient))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
        let loaded = expectation(description: "Local HTML loaded")
        let probe = PreviewNavigationProbe(loaded: loaded)
        webView.navigationDelegate = probe
        webView.load(URLRequest(url: loader.entryURL))
        await fulfillment(of: [loaded], timeout: 15)
        let inspected = expectation(description: "Policy inspected")
        webView.evaluateJavaScript("""
            document.querySelector('#count').click();
            ({inlineRan:window.inlineRan, localRan:window.localRan, fetchBlocked:window.fetchBlocked,
              violations:window.violations, color:getComputedStyle(document.body).color,
              button:document.querySelector('#count').textContent, bridge:!!window.webkit?.messageHandlers?.toasttyLocalDocumentPanel})
            """) { value, error in
            XCTAssertNil(error)
            let result = value as? [String: Any]
            XCTAssertEqual(result?["inlineRan"] as? Bool, true)
            XCTAssertEqual(result?["localRan"] as? Bool, true)
            XCTAssertEqual(result?["fetchBlocked"] as? Bool, true)
            XCTAssertEqual(result?["button"] as? String, "Count: 1")
            XCTAssertEqual(result?["color"] as? String, "rgb(1, 2, 3)")
            XCTAssertEqual(result?["bridge"] as? Bool, false)
            let violations = result?["violations"] as? [String] ?? []
            XCTAssertTrue(violations.contains("connect-src"), "\(violations)")
            XCTAssertTrue(violations.contains("img-src"), "\(violations)")
            XCTAssertTrue(violations.contains("frame-src"), "\(violations)")
            inspected.fulfill()
        }
        await fulfillment(of: [inspected], timeout: 5)
        let syntheticRejected = expectation(description: "Synthetic link cannot forge a trusted navigation")
        webView.evaluateJavaScript("""
            window.ToasttyConsumeTrustedLink = () => true;
            const link = document.createElement('a'); link.href = 'https://example.com/';
            document.body.append(link); link.click();
            """) { _, error in
            XCTAssertNil(error)
            webView.evaluateJavaScript("window.ToasttyConsumeTrustedLink('https://example.com/')",
                                       in: nil, in: .defaultClient) { result in
                guard case .success(let value) = result else {
                    XCTFail("Trusted navigation guard unavailable")
                    syntheticRejected.fulfill()
                    return
                }
                XCTAssertEqual(value as? Bool, false)
                syntheticRejected.fulfill()
            }
        }
        await fulfillment(of: [syntheticRejected], timeout: 5)
        webView.stopLoading()
        loader.cancelAll()
        withExtendedLifetime(probe) {}
    }
}

@MainActor
private final class PreviewNavigationProbe: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == ToasttyHTMLPreviewPolicy.scheme ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        XCTFail("HTML preview failed: \(error)")
        loaded.fulfill()
    }
}

@MainActor
private final class PreviewSchemeTask: NSObject, @MainActor WKURLSchemeTask {
    let request: URLRequest
    var callbacks: [String] = []
    init(request: URLRequest) { self.request = request }
    func didReceive(_ response: URLResponse) { callbacks.append("response") }
    func didReceive(_ data: Data) { callbacks.append("data") }
    func didFinish() { callbacks.append("finish") }
    func didFailWithError(_ error: any Error) { callbacks.append("error") }
}
