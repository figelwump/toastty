import AppKit
import Combine
@testable import ToasttyApp
import CoreState
import WebKit
import XCTest

@MainActor
final class ScratchpadPanelRuntimeTests: XCTestCase {
    func testAnnotationReadinessRejectsEarlierRenderWithSameTitleAndRevision() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let recorder = ScratchpadBridgeScriptRecorder()
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(), documentStore: fixture.store,
            metadataDidChange: { _, _, _ in }, interactionDidRequestFocus: { _ in },
            bridgeScriptEvaluator: recorder.evaluate, diagnosticLogger: { _, _, _ in }
        )
        let document = try fixture.store.createDocument(title: "Sketch", content: "<h1>Sketch</h1>", sessionLink: nil)
        let webState = WebPanelState(
            definition: .scratchpad,
            scratchpad: ScratchpadState(documentID: document.documentID, revision: document.revision)
        )
        runtime.reloadBootstrap(for: webState)
        runtime.simulateBridgeReadyForTesting()
        let firstScript = try XCTUnwrap(recorder.scripts.last)
        let firstRenderID = String(try XCTUnwrap(firstScript.components(separatedBy: "annotationRenderID: \"").last).prefix(36))
        XCTAssertNotNil(UUID(uuidString: firstRenderID))
        runtime.reloadBootstrap(for: webState)
        let nextScript = try XCTUnwrap(recorder.scripts.last)
        let nextRenderID = String(try XCTUnwrap(nextScript.components(separatedBy: "annotationRenderID: \"").last).prefix(36))
        XCTAssertNotEqual(firstRenderID, nextRenderID)

        runtime.simulateBridgeMessageForTesting([
            "type": "renderReady", "displayName": "Sketch", "revision": 1,
            "annotationRenderID": firstRenderID,
        ])
        XCTAssertFalse(runtime.isAnnotationContentReady)

        runtime.simulateBridgeMessageForTesting([
            "type": "renderReady", "displayName": "Sketch", "revision": 1,
            "annotationRenderID": nextRenderID,
        ])
        XCTAssertTrue(runtime.isAnnotationContentReady)
    }

    func testSendingScratchpadAnnotationsBuildsPayloadAndClearsOnlyAfterSuccess() async throws {
        let fixture = try ScratchpadRuntimeFixture()
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(), documentStore: fixture.store,
            metadataDidChange: { _, _, _ in }, interactionDidRequestFocus: { _ in },
            diagnosticLogger: { _, _, _ in }
        )
        runtime.setAnnotationModeEnabled(true)
        runtime.recordAnnotation(
            in: BrowserAnnotationCapturedSection(
                pngData: BrowserAnnotationTestImage.pngData(width: 40, height: 40),
                url: nil, title: "Review diagram, revision 1", scrollOffset: .zero,
                viewportSize: CGSize(width: 40, height: 40), capturedAt: Date()
            ),
            kind: .point(CGPoint(x: 0.5, y: 0.5)), comment: "Move this heading"
        )
        let candidate = BrowserScreenshotSendCandidate(
            sessionID: "test-agent", agent: .codex, panelID: UUID(), label: "Test Agent"
        )
        let sent = expectation(description: "Scratchpad annotation payload sent through callback")
        var screenshotURL: URL?
        BrowserAnnotationSendFlow.send(
            runtime: runtime, candidate: candidate, availability: { _ in .available }
        ) { payload, destination in
            XCTAssertEqual(destination, candidate)
            XCTAssertTrue(payload.hasPrefix("Scratchpad annotation feedback from Toastty."))
            XCTAssertTrue(payload.contains("1. Move this heading"))
            XCTAssertTrue(runtime.annotationState.hasDrafts)
            if let screenshotLine = payload.components(separatedBy: "\n").first(where: { $0.hasPrefix("Screenshot 1: ") }) {
                screenshotURL = URL(fileURLWithPath: String(screenshotLine.dropFirst("Screenshot 1: ".count)))
            }
            sent.fulfill()
            return true
        }
        await fulfillment(of: [sent], timeout: 5)
        if let screenshotURL {
            try? FileManager.default.removeItem(at: screenshotURL)
        }
        XCTAssertFalse(runtime.annotationState.hasDrafts)
        XCTAssertFalse(runtime.annotationState.isAnnotationModeEnabled)
        XCTAssertFalse(runtime.isAnnotationSendInFlight)
    }

    func testAnnotationCaptureReadsIframeScrollAndIdentifiesScratchpadRevision() async throws {
        let fixture = try ScratchpadRuntimeFixture()
        let document = try fixture.store.createDocument(
            title: "Review diagram",
            content: """
            <!doctype html><html><head><style>body { margin: 0; height: 2000px; }</style></head>
            <body><h1>Review diagram</h1><script>
            window.addEventListener('load', () => window.scrollTo(0, 180));
            </script></body></html>
            """,
            sessionLink: nil
        )
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(), documentStore: fixture.store,
            metadataDidChange: { _, _, _ in }, interactionDidRequestFocus: { _ in },
            diagnosticLogger: { _, _, _ in }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        window.contentView = container
        window.orderFront(nil)
        defer { window.close() }
        runtime.attachHost(to: container, attachment: PanelHostAttachmentToken.next())
        runtime.apply(webState: WebPanelState(
            definition: .scratchpad,
            scratchpad: ScratchpadState(documentID: document.documentID, revision: document.revision)
        ))
        let deadline = Date().addingTimeInterval(10)
        while runtime.isAnnotationContentReady == false, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(runtime.isAnnotationContentReady)

        let section = try await runtime.captureAnnotationSection(capturedAt: Date(timeIntervalSince1970: 123))

        XCTAssertEqual(section.scrollOffset.y, 180, accuracy: 1)
        XCTAssertEqual(section.viewportSize, CGSize(width: 320, height: 200))
        XCTAssertNil(section.url)
        XCTAssertTrue(section.title?.contains(document.documentID.uuidString) == true)
        XCTAssertTrue(section.title?.contains("revision 1") == true)
        XCTAssertEqual(section.capturedAt, Date(timeIntervalSince1970: 123))
        XCTAssertNotNil(NSBitmapImageRep(data: section.pngData))
    }

    func testAnnotationDraftsPublishAndInvalidateWhenScratchpadReloads() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(), documentStore: fixture.store,
            metadataDidChange: { _, _, _ in }, interactionDidRequestFocus: { _ in },
            diagnosticLogger: { _, _, _ in }
        )
        var changeCount = 0
        let observation = runtime.objectWillChange.sink { changeCount += 1 }
        defer { observation.cancel() }
        runtime.setAnnotationModeEnabled(true)
        let annotation = runtime.recordAnnotation(
            in: BrowserAnnotationCapturedSection(
                pngData: Data(), url: nil, title: "Scratchpad",
                scrollOffset: .zero, viewportSize: CGSize(width: 320, height: 200),
                capturedAt: Date()
            ),
            kind: .point(CGPoint(x: 0.5, y: 0.5)), comment: "Move this heading"
        )
        XCTAssertGreaterThan(changeCount, 0)
        XCTAssertTrue(runtime.updateAnnotationComment(annotationID: annotation.id, comment: "Updated"))
        XCTAssertEqual(runtime.annotationState.annotationItem(withID: annotation.id)?.comment, "Updated")
        runtime.setAnnotationEditorActive(true)
        let generation = runtime.currentAnnotationPageGeneration()

        runtime.reloadBootstrap(for: WebPanelState(
            definition: .scratchpad,
            scratchpad: ScratchpadState(documentID: UUID(), revision: 2)
        ))

        XCTAssertFalse(runtime.annotationState.hasDrafts)
        XCTAssertFalse(runtime.annotationState.isAnnotationModeEnabled)
        XCTAssertFalse(runtime.isAnnotationEditorActive)
        XCTAssertGreaterThan(runtime.currentAnnotationPageGeneration(), generation)
        XCTAssertFalse(runtime.isAnnotationContentReady)
    }

    func testAnnotationModePreventsWebViewFocusFromStealingEditorFocus() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let recorder = ScratchpadBridgeScriptRecorder()
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(), documentStore: fixture.store,
            metadataDidChange: { _, _, _ in }, interactionDidRequestFocus: { _ in },
            bridgeScriptEvaluator: recorder.evaluate, diagnosticLogger: { _, _, _ in }
        )
        let window = ScratchpadFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: PanelHostAttachmentToken.next())
        runtime.setAnnotationModeEnabled(true)
        runtime.setAnnotationEditorActive(true)

        XCTAssertTrue(runtime.focusWebView())
        runtime.simulateBridgeMessageForTesting([
            "type": "renderReady", "displayName": "Sketch", "revision": 1,
        ])

        XCTAssertEqual(window.makeFirstResponderCallCount, 0)
        XCTAssertTrue(recorder.scripts.isEmpty)
        XCTAssertTrue(runtime.isAnnotationEditorActive)
    }

    func testThemeBootstrapReplacementInvalidatesAnnotations() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let recorder = ScratchpadBridgeScriptRecorder()
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(), documentStore: fixture.store,
            metadataDidChange: { _, _, _ in }, interactionDidRequestFocus: { _ in },
            bridgeScriptEvaluator: recorder.evaluate, diagnosticLogger: { _, _, _ in }
        )
        runtime.reloadBootstrap(for: WebPanelState(
            definition: .scratchpad,
            scratchpad: ScratchpadState(documentID: UUID(), revision: 1)
        ))
        runtime.simulateBridgeReadyForTesting()
        runtime.setAnnotationModeEnabled(true)
        runtime.setAnnotationEditorActive(true)
        let generation = runtime.currentAnnotationPageGeneration()

        runtime.applyEffectiveAppearance(NSAppearance(named: .aqua))

        XCTAssertGreaterThan(runtime.currentAnnotationPageGeneration(), generation)
        XCTAssertFalse(runtime.annotationState.isAnnotationModeEnabled)
        XCTAssertFalse(runtime.isAnnotationEditorActive)
    }

    func testExternalLinksRouteOnlyWebURLsFromIsolatedHandler() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let panelID = UUID()
        var opened: [URL] = []
        let runtime = ScratchpadPanelRuntime(
            panelID: panelID,
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            openExternalLink: { sourcePanelID, url in
                XCTAssertEqual(sourcePanelID, panelID)
                opened.append(url)
            },
            diagnosticLogger: { _, _, _ in }
        )
        for url in ["https://example.com/path#section", "http://example.com/"] {
            runtime.handleExternalLinkMessage(url)
        }
        for url in ["#section", "file:///tmp/example.html", "javascript:alert(1)", "mailto:a@example.com", "https:", "https:///", "relative"] {
            runtime.handleExternalLinkMessage(url)
        }
        // The page-world bridge must not expose the isolated link-opening capability.
        runtime.simulateBridgeMessageForTesting(["type": "openExternalLink", "url": "https://ignored.example"])
        runtime.handleExternalLinkMessage(["url": "https://ignored.example"])
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/path#section", "http://example.com/"])
    }

    func testExternalLinkHandlerIsUnavailableToPageScripts() async throws {
        let fixture = try ScratchpadRuntimeFixture()
        let routed = expectation(description: "isolated handler routes URL")
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(),
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            openExternalLink: { _, url in
                XCTAssertEqual(url.absoluteString, "https://example.com/")
                routed.fulfill()
            },
            diagnosticLogger: { _, _, _ in }
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        runtime.attachHost(to: container, attachment: PanelHostAttachmentToken.next())
        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        let ready = expectation(description: "bundled page loaded")
        let handler = ScratchpadPanelTestMessageHandler()
        handler.bridgeReadyExpectation = ready
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "toasttyScratchpadPanel")
        webView.configuration.userContentController.add(handler, name: "toasttyScratchpadPanel")
        let entryURL = try XCTUnwrap(ScratchpadPanelAssetLocator.entryURL())
        webView.loadFileURL(entryURL, allowingReadAccessTo: entryURL.deletingLastPathComponent())
        await fulfillment(of: [ready], timeout: 5)

        let pageAccess = try await webView.evaluateJavaScript(
            "typeof window.webkit?.messageHandlers?.toasttyScratchpadExternalLink"
        )
        XCTAssertEqual(pageAccess as? String, "undefined")
        _ = try await webView.evaluateJavaScript(
            "window.webkit.messageHandlers.toasttyScratchpadExternalLink.postMessage('https://example.com/'); true",
            in: nil,
            in: .defaultClient
        )
        await fulfillment(of: [routed], timeout: 5)
    }

    func testScratchpadRuntimeOptsIntoHistoryContextMenuItems() throws {
        let fixture = try ScratchpadRuntimeFixture()
        let runtime = ScratchpadPanelRuntime(
            panelID: UUID(),
            documentStore: fixture.store,
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in },
            diagnosticLogger: { _, _, _ in }
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        runtime.attachHost(to: container, attachment: PanelHostAttachmentToken.next())

        let webView = try XCTUnwrap(container.subviews.first as? FocusAwareWKWebView)
        XCTAssertTrue(webView.showsHistoryContextMenuItems)
    }

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
