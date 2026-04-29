import AppKit
@testable import ToasttyApp
import CoreState
import WebKit
import XCTest

@MainActor
final class ScratchpadPanelRuntimeTests: XCTestCase {
    func testLocalOnlyCapabilityProfileUsesNonPersistentWebsiteDataStore() {
        let configuration = ScratchpadPanelRuntime.makeWebViewConfiguration(for: .localOnly)

        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    }

    func testAssetLocatorResolvesFolderReferencedPanelBundle() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resourcesDirectoryURL = tempDirectoryURL
            .appendingPathComponent("Test.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let panelDirectoryURL = resourcesDirectoryURL
            .appendingPathComponent("WebPanels", isDirectory: true)
            .appendingPathComponent("scratchpad-panel", isDirectory: true)
        let entryURL = panelDirectoryURL.appendingPathComponent("index.html")

        try FileManager.default.createDirectory(at: panelDirectoryURL, withIntermediateDirectories: true)
        try Data("<!doctype html>".utf8).write(to: entryURL)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let bundleURL = tempDirectoryURL.appendingPathComponent("Test.app", isDirectory: true)
        let bundle = try XCTUnwrap(Bundle(path: bundleURL.path))

        XCTAssertEqual(ScratchpadPanelAssetLocator.entryURL(bundle: bundle), entryURL)
        XCTAssertEqual(ScratchpadPanelAssetLocator.directoryURL(bundle: bundle), panelDirectoryURL)
    }

    func testBundledScratchpadPanelRunsGeneratedInlineScripts() async throws {
        let assetDirectoryURL = try XCTUnwrap(ScratchpadPanelAssetLocator.directoryURL())
        let entryURL = assetDirectoryURL.appendingPathComponent("index.html")
        let handler = ScratchpadPanelTestMessageHandler()
        let configuration = ScratchpadPanelRuntime.makeWebViewConfiguration(for: .localOnly)
        configuration.userContentController.add(handler, name: "toasttyScratchpadPanel")
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: "toasttyScratchpadPanel")
        }

        let bridgeReady = expectation(description: "Scratchpad bridge becomes ready")
        let scriptRan = expectation(description: "generated inline script runs")
        let clickRan = expectation(description: "generated addEventListener click handler runs")
        let keyRan = expectation(description: "generated addEventListener key handler runs")
        let inlineAttributeRan = expectation(description: "generated inline event attribute is blocked")
        inlineAttributeRan.isInverted = true
        handler.bridgeReadyExpectation = bridgeReady
        handler.expectedGeneratedMessages = [
            "scratchpad-js-ran": scriptRan,
            "scratchpad-click-ran": clickRan,
            "scratchpad-key-ran": keyRan,
        ]
        handler.unexpectedGeneratedMessages = [
            "scratchpad-inline-attr-ran": inlineAttributeRan,
        ]

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        webView.loadFileURL(entryURL, allowingReadAccessTo: assetDirectoryURL)

        await fulfillment(of: [bridgeReady], timeout: 5)

        let bootstrapScript = try XCTUnwrap(ScratchpadPanelRuntime.bootstrapJavaScript(
            for: ScratchpadPanelBootstrap(
                documentID: UUID(),
                displayName: "JavaScript Fixture",
                revision: 1,
                contentHTML: """
                <!doctype html>
                <html>
                  <head><title>JavaScript Fixture</title></head>
                  <body>
                    <p id="status">booting</p>
                    <button id="listener" type="button">Listener</button>
                    <button id="attribute" type="button" onclick="console.info('scratchpad-inline-attr-ran')">Attribute</button>
                    <script>
                    (() => {
                      document.getElementById('status').textContent = 'js-ready';
                      console.info('scratchpad-js-ran');
                      const listener = document.getElementById('listener');
                      listener.addEventListener('click', () => console.info('scratchpad-click-ran'));
                      listener.click();
                      document.addEventListener('keydown', () => console.info('scratchpad-key-ran'));
                      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'k' }));
                      document.getElementById('attribute').click();
                    })();
                    </script>
                  </body>
                </html>
                """,
                theme: .dark
            )
        ))

        _ = try await webView.evaluateJavaScript(bootstrapScript)

        await fulfillment(of: [scriptRan, clickRan, keyRan], timeout: 5)
        await fulfillment(of: [inlineAttributeRan], timeout: 0.3)
    }

    func testBootstrapLoadsPersistedDocument() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let document = try fixture.store.createDocument(
            title: "Sketch",
            content: "<strong>Visible</strong>",
            sessionLink: nil
        )
        let webState = WebPanelState(
            definition: .scratchpad,
            title: "Scratchpad",
            scratchpad: ScratchpadState(
                documentID: document.documentID,
                revision: document.revision
            )
        )

        let bootstrap = ScratchpadPanelRuntime.bootstrap(
            for: webState,
            documentStore: fixture.store,
            theme: .dark
        )

        XCTAssertEqual(bootstrap.documentID, document.documentID)
        XCTAssertEqual(bootstrap.displayName, "Sketch")
        XCTAssertEqual(bootstrap.revision, 1)
        XCTAssertEqual(bootstrap.contentHTML, "<strong>Visible</strong>")
        XCTAssertFalse(bootstrap.missingDocument)
        XCTAssertFalse(bootstrap.sessionLinked)
    }

    func testBootstrapMarksSessionLinkedDocument() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let sessionLink = ScratchpadSessionLink(
            sessionID: "session-1",
            agent: .codex,
            sourcePanelID: UUID(),
            sourceWorkspaceID: UUID()
        )
        let document = try fixture.store.createDocument(
            title: "Sketch",
            content: "",
            sessionLink: sessionLink
        )
        let webState = WebPanelState(
            definition: .scratchpad,
            title: "Scratchpad",
            scratchpad: ScratchpadState(
                documentID: document.documentID,
                sessionLink: sessionLink,
                revision: document.revision
            )
        )

        let bootstrap = ScratchpadPanelRuntime.bootstrap(
            for: webState,
            documentStore: fixture.store,
            theme: .dark
        )

        XCTAssertEqual(bootstrap.documentID, document.documentID)
        XCTAssertEqual(bootstrap.revision, 1)
        XCTAssertEqual(bootstrap.contentHTML, "")
        XCTAssertTrue(bootstrap.sessionLinked)
    }

    func testBootstrapReportsMissingDocument() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let documentID = UUID()
        let webState = WebPanelState(
            definition: .scratchpad,
            title: "Scratchpad",
            scratchpad: ScratchpadState(
                documentID: documentID,
                revision: 3
            )
        )

        let bootstrap = ScratchpadPanelRuntime.bootstrap(
            for: webState,
            documentStore: fixture.store,
            theme: .light
        )

        XCTAssertEqual(bootstrap.documentID, documentID)
        XCTAssertEqual(bootstrap.revision, 3)
        XCTAssertTrue(bootstrap.missingDocument)
        XCTAssertNil(bootstrap.contentHTML)
    }

    func testBlankScratchpadOnboardingOnlyAppliesToUnboundDocuments() async throws {
        let assetDirectoryURL = try XCTUnwrap(ScratchpadPanelAssetLocator.directoryURL())
        let entryURL = assetDirectoryURL.appendingPathComponent("index.html")
        let handler = ScratchpadPanelTestMessageHandler()
        let configuration = ScratchpadPanelRuntime.makeWebViewConfiguration(for: .localOnly)
        configuration.userContentController.add(handler, name: "toasttyScratchpadPanel")
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: "toasttyScratchpadPanel")
        }

        let bridgeReady = expectation(description: "Scratchpad bridge becomes ready")
        handler.bridgeReadyExpectation = bridgeReady

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        webView.loadFileURL(entryURL, allowingReadAccessTo: assetDirectoryURL)

        await fulfillment(of: [bridgeReady], timeout: 5)

        let unboundBootstrapScript = try XCTUnwrap(ScratchpadPanelRuntime.bootstrapJavaScript(
            for: ScratchpadPanelBootstrap(
                documentID: UUID(),
                displayName: "Unbound Scratchpad",
                revision: 1,
                contentHTML: "",
                theme: .dark
            )
        ))
        _ = try await webView.evaluateJavaScript(unboundBootstrapScript)
        let unboundGuideResult = try await webView.evaluateJavaScript(
            "document.querySelector('.scratchpad-empty--guide') !== null"
        )
        let unboundHasGuide = try XCTUnwrap(unboundGuideResult as? Bool)
        XCTAssertTrue(unboundHasGuide)

        let linkedBootstrapScript = try XCTUnwrap(ScratchpadPanelRuntime.bootstrapJavaScript(
            for: ScratchpadPanelBootstrap(
                documentID: UUID(),
                displayName: "Linked Scratchpad",
                revision: 1,
                contentHTML: "",
                sessionLinked: true,
                theme: .dark
            )
        ))
        _ = try await webView.evaluateJavaScript(linkedBootstrapScript)
        let linkedGuideResult = try await webView.evaluateJavaScript(
            "document.querySelector('.scratchpad-empty--guide') !== null"
        )
        let linkedFrameResult = try await webView.evaluateJavaScript(
            "document.querySelector('.scratchpad-frame') !== null"
        )
        let linkedHasGuide = try XCTUnwrap(linkedGuideResult as? Bool)
        let linkedHasFrame = try XCTUnwrap(linkedFrameResult as? Bool)
        XCTAssertFalse(linkedHasGuide)
        XCTAssertTrue(linkedHasFrame)
    }

    func testBridgeIgnoresSubframeMessagesInTestingShim() throws {
        let fixture = try ScratchpadRuntimeFixture()
        var logs: [(ToasttyLogLevel, String)] = []
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(),
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            diagnosticLogger: { level, message, _ in
                logs.append((level, message))
            }
        )

        runtime.simulateBridgeMessageForTesting(
            ["type": "consoleMessage", "level": "error", "message": "from generated frame"],
            isMainFrame: false
        )

        XCTAssertTrue(logs.isEmpty)
        XCTAssertTrue(runtime.automationState().recentDiagnostics.isEmpty)
    }

    func testGeneratedContentDiagnosticsAreRecordedInAutomationState() throws {
        let fixture = try ScratchpadRuntimeFixture()
        var logs: [(ToasttyLogLevel, String, [String: String])] = []
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(),
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            diagnosticLogger: { level, message, metadata in
                logs.append((level, message, metadata))
            }
        )

        runtime.simulateBridgeMessageForTesting([
            "type": "javascriptError",
            "diagnosticSource": "generated-content",
            "message": "Cannot read properties of null",
            "source": "about:srcdoc",
            "line": 14,
            "column": 9,
            "stack": "render@about:srcdoc:14:9",
        ])

        let diagnostic = try XCTUnwrap(runtime.automationState().recentDiagnostics.first)
        XCTAssertEqual(diagnostic.source, "generated-content")
        XCTAssertEqual(diagnostic.kind, "javascript-error")
        XCTAssertEqual(diagnostic.level, "error")
        XCTAssertEqual(diagnostic.message, "Cannot read properties of null")
        XCTAssertEqual(diagnostic.metadata["source"], "about:srcdoc")
        XCTAssertEqual(diagnostic.metadata["line"], "14")
        XCTAssertEqual(diagnostic.metadata["column"], "9")
        XCTAssertEqual(diagnostic.metadata["stack"], "render@about:srcdoc:14:9")
        XCTAssertEqual(logs.last?.0, .error)
        XCTAssertEqual(logs.last?.1, "Scratchpad JavaScript error")
        XCTAssertEqual(logs.last?.2["diagnostic_source"], "generated-content")
    }

    func testContentSecurityPolicyViolationsAreRecordedInAutomationState() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(),
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            diagnosticLogger: { _, _, _ in }
        )

        runtime.simulateBridgeMessageForTesting([
            "type": "cspViolation",
            "diagnosticSource": "generated-content",
            "violatedDirective": "connect-src",
            "effectiveDirective": "connect-src",
            "blockedURI": "https://example.com/data.json",
            "sourceFile": "about:srcdoc",
            "line": 22,
            "column": 5,
            "disposition": "enforce",
        ])

        let diagnostic = try XCTUnwrap(runtime.automationState().recentDiagnostics.first)
        XCTAssertEqual(diagnostic.source, "generated-content")
        XCTAssertEqual(diagnostic.kind, "csp-violation")
        XCTAssertEqual(diagnostic.level, "warn")
        XCTAssertEqual(diagnostic.message, "Blocked https://example.com/data.json by connect-src")
        XCTAssertEqual(diagnostic.metadata["violatedDirective"], "connect-src")
        XCTAssertEqual(diagnostic.metadata["effectiveDirective"], "connect-src")
        XCTAssertEqual(diagnostic.metadata["blockedURI"], "https://example.com/data.json")
        XCTAssertEqual(diagnostic.metadata["sourceFile"], "about:srcdoc")
    }

    func testDiagnosticsResetWhenBootstrapReloads() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(),
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            diagnosticLogger: { _, _, _ in }
        )
        let document = try fixture.store.createDocument(
            title: "Sketch",
            content: "<strong>Visible</strong>",
            sessionLink: nil
        )
        let webState = WebPanelState(
            definition: .scratchpad,
            title: "Scratchpad",
            scratchpad: ScratchpadState(
                documentID: document.documentID,
                revision: document.revision
            )
        )

        runtime.simulateBridgeMessageForTesting([
            "type": "consoleMessage",
            "diagnosticSource": "generated-content",
            "level": "error",
            "message": "before reload",
        ])
        XCTAssertEqual(runtime.automationState().recentDiagnostics.count, 1)

        runtime.reloadBootstrap(for: webState)

        XCTAssertTrue(runtime.automationState().recentDiagnostics.isEmpty)
    }

    func testFocusActiveContentJavaScriptTargetsScratchpadBridge() {
        let script = ScratchpadPanelRuntime.focusActiveContentJavaScript()

        XCTAssertTrue(script.contains("window.ToasttyScratchpadPanel"))
        XCTAssertTrue(script.contains("return bridge.focusActiveContent();"))
    }

    func testFocusWebViewDefersGeneratedContentFocusUntilRenderReady() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let entryURL = fixture.directoryURL.appendingPathComponent("scratchpad-test.html")
        try Data("<!doctype html><html><body></body></html>".utf8).write(to: entryURL)
        let recorder = ScratchpadBridgeScriptRecorder(results: [true, false, true])
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(),
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            entryURL: entryURL,
            bridgeScriptEvaluator: recorder.evaluate,
            diagnosticLogger: { _, _, _ in }
        )
        let document = try fixture.store.createDocument(
            title: "Sketch",
            content: "<p>Focusable</p>",
            sessionLink: nil
        )
        let webState = WebPanelState(
            definition: .scratchpad,
            title: "Scratchpad",
            scratchpad: ScratchpadState(
                documentID: document.documentID,
                revision: document.revision
            )
        )
        let window = ScratchpadFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: PanelHostAttachmentToken.next())
        runtime.reloadBootstrap(for: webState)

        XCTAssertTrue(runtime.focusWebView())
        XCTAssertEqual(window.makeFirstResponderCallCount, 1)
        XCTAssertTrue(recorder.scripts.isEmpty)

        runtime.simulateBridgeReadyForTesting()

        XCTAssertEqual(recorder.scripts.count, 2)
        XCTAssertTrue(recorder.scripts[0].contains("bridge.receiveBootstrap("))
        XCTAssertTrue(recorder.scripts[1].contains("bridge.focusActiveContent()"))

        runtime.simulateBridgeMessageForTesting([
            "type": "renderReady",
            "displayName": "Sketch",
            "revision": 1,
        ])

        XCTAssertEqual(recorder.scripts.count, 3)
        XCTAssertTrue(recorder.scripts[2].contains("bridge.focusActiveContent()"))
    }
}

private struct ScratchpadRuntimeFixture {
    let directoryURL: URL
    let store: ScratchpadDocumentStore

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        store = ScratchpadDocumentStore(directoryURL: directoryURL)
    }
}

@MainActor
private final class ScratchpadBridgeScriptRecorder {
    private var results: [Any?]
    private(set) var scripts: [String] = []

    init(results: [Any?] = []) {
        self.results = results
    }

    func evaluate(_ script: String, completion: @escaping ScratchpadPanelRuntime.BridgeScriptCompletion) {
        scripts.append(script)
        let result = results.isEmpty ? true : results.removeFirst()
        completion(result, nil)
    }
}

@MainActor
private final class ScratchpadFocusTestWindow: NSWindow {
    private(set) var makeFirstResponderCallCount = 0
    private var storedFirstResponder: NSResponder?

    override var firstResponder: NSResponder? {
        storedFirstResponder
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        makeFirstResponderCallCount += 1
        storedFirstResponder = responder
        return true
    }
}

private final class ScratchpadPanelTestMessageHandler: NSObject, WKScriptMessageHandler {
    var bridgeReadyExpectation: XCTestExpectation?
    var expectedGeneratedMessages: [String: XCTestExpectation] = [:]
    var unexpectedGeneratedMessages: [String: XCTestExpectation] = [:]

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "toasttyScratchpadPanel",
              message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }

        switch type {
        case "bridgeReady":
            bridgeReadyExpectation?.fulfill()
            bridgeReadyExpectation = nil
        case "consoleMessage":
            guard (body["diagnosticSource"] as? String) == "generated-content",
                  let consoleMessage = body["message"] as? String else {
                return
            }
            expectedGeneratedMessages.removeValue(forKey: consoleMessage)?.fulfill()
            unexpectedGeneratedMessages[consoleMessage]?.fulfill()
        default:
            return
        }
    }
}
