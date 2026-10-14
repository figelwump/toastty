import AppKit
@testable import ToasttyApp
import WebKit
import XCTest

@MainActor
final class LocalDocumentPanelActionTests: XCTestCase {
    func testCodeLineRevealAlignsContentAndGutterAndClampsScrolling() async throws {
        let assetDirectoryURL = try XCTUnwrap(LocalDocumentPanelAssetLocator.directoryURL())
        let bridgeReady = expectation(description: "Local document bridge becomes ready")
        let renderReady = expectation(description: "Code document renders")
        let handler = LocalDocumentActionMessageHandler(bridgeReady: bridgeReady, renderReady: renderReady)
        let configuration = LocalDocumentPanelRuntime.makeWebViewConfiguration(for: .localOnly)
        configuration.userContentController.add(handler, name: "toasttyLocalDocumentPanel")
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        // WebKit schedules reveal frames only while the test window is on screen.
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil)
            webView.stopLoading()
            configuration.userContentController.removeScriptMessageHandler(forName: "toasttyLocalDocumentPanel")
        }
        webView.loadFileURL(
            assetDirectoryURL.appendingPathComponent("index.html"),
            allowingReadAccessTo: assetDirectoryURL
        )
        await fulfillment(of: [bridgeReady], timeout: 5)

        let content = (1...240).map { line in
            switch line {
            case 120: ""
            case 180: "x"
            default: "let value\(line) = \(line)"
            }
        }.joined(separator: "\n")
        let bootstrap = LocalDocumentPanelBootstrap(
            filePath: "/tmp/toastty-reveal-tests/example.swift",
            displayName: "readme.md",
            format: .code,
            syntaxLanguage: .swift,
            content: content,
            contentRevision: 1,
            theme: .light
        )
        let bootstrapScript = try XCTUnwrap(LocalDocumentPanelRuntime.bootstrapJavaScript(for: bootstrap))
        _ = try await webView.evaluateJavaScript(bootstrapScript)
        await fulfillment(of: [renderReady], timeout: 5)

        let result = try await webView.callAsyncJavaScript(
            """
            const nextFrame = () => new Promise((resolve, reject) => {
              const timeout = setTimeout(() => reject(new Error('Animation frame did not run')), 2000);
              requestAnimationFrame(() => { clearTimeout(timeout); resolve(); });
            });
            async function waitFor(read, message) {
              const deadline = performance.now() + 5000;
              while (performance.now() < deadline) {
                const value = read();
                if (value) return value;
                await new Promise(resolve => setTimeout(resolve, 20));
              }
              throw new Error(message);
            }
            await waitFor(() => document.visibilityState === 'visible', 'Code test window is not visible');
            await document.fonts.ready;
            await waitFor(
              () => document.querySelector('.local-document-code-content code .hljs-keyword'),
              'Swift syntax highlighting did not render'
            );
            const scroll = document.querySelector('.local-document-code-scroll');
            if (!scroll || scroll.clientHeight <= 0) throw new Error('Code viewport has no height');
            const samples = [];
            let previousTop = null;
            for (const line of [1, 120, 180, 240]) {
              window.ToasttyLocalDocumentPanel.revealLine(line);
              const band = await waitFor(() => {
                const band = document.querySelector('.local-document-code-line-reveal');
                return band && band.style.top !== previousTop
                  && window.ToasttyLocalDocumentPanel.getCurrentRevealRequest() === null && band;
              }, 'Requested reveal band did not render');
              previousTop = band.style.top;
              let lastScrollTop = null;
              let stableFrames = 0;
              const deadline = performance.now() + 5000;
              while (stableFrames < 2) {
                if (performance.now() >= deadline) throw new Error('Reveal scroll did not settle');
                await nextFrame();
                stableFrames = scroll.scrollTop === lastScrollTop ? stableFrames + 1 : 0;
                lastScrollTop = scroll.scrollTop;
              }
              const gutter = document.querySelector('.local-document-code-gutter');
              const gutterBand = document.querySelector('.local-document-code-gutter-reveal');
              if (!gutter || !gutterBand) throw new Error('Gutter did not render');
              const lines = gutter.textContent.split('\\n');
              const offset = lines.slice(0, line - 1).reduce((total, text) => total + text.length + 1, 0);
              const lastDigit = offset + lines[line - 1].length - 1;
              const range = document.createRange();
              range.setStart(gutter.firstChild, lastDigit);
              range.setEnd(gutter.firstChild, lastDigit + 1);
              const glyphRects = range.getClientRects();
              const glyph = glyphRects[glyphRects.length - 1];
              if (!glyph) throw new Error('Requested line number has no glyph rectangle');
              const contentRect = band.getBoundingClientRect();
              const gutterRect = gutterBand.getBoundingClientRect();
              const viewport = scroll.getBoundingClientRect();
              samples.push({
                line, contentTop: contentRect.top, contentBottom: contentRect.bottom,
                gutterTop: gutterRect.top, gutterBottom: gutterRect.bottom,
                glyphTop: glyph.top, glyphBottom: glyph.bottom,
                viewportTop: viewport.top, viewportBottom: viewport.bottom,
                relativeCenter: ((contentRect.top + contentRect.bottom) / 2 - viewport.top) / viewport.height
              });
            }
            return samples;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let samples = try XCTUnwrap(result as? [[String: Double]])
        XCTAssertEqual(samples.count, 4)
        for sample in samples {
            let line = try XCTUnwrap(sample["line"])
            let top = try XCTUnwrap(sample["contentTop"])
            let bottom = try XCTUnwrap(sample["contentBottom"])
            XCTAssertEqual(top, try XCTUnwrap(sample["gutterTop"]), accuracy: 1, "Line \(line)")
            XCTAssertEqual(bottom, try XCTUnwrap(sample["gutterBottom"]), accuracy: 1, "Line \(line)")
            XCTAssertLessThanOrEqual(top, try XCTUnwrap(sample["glyphTop"]) + 1, "Line \(line)")
            XCTAssertGreaterThanOrEqual(bottom, try XCTUnwrap(sample["glyphBottom"]) - 1, "Line \(line)")
            XCTAssertGreaterThanOrEqual(top, try XCTUnwrap(sample["viewportTop"]) - 1, "Line \(line)")
            XCTAssertLessThanOrEqual(bottom, try XCTUnwrap(sample["viewportBottom"]) + 1, "Line \(line)")
            if line == 120 || line == 180 {
                let relativeCenter = try XCTUnwrap(sample["relativeCenter"])
                XCTAssertGreaterThan(relativeCenter, 0.2)
                XCTAssertLessThan(relativeCenter, 0.5)
            }
        }
    }

    func testReadModeButtonsSendNativeActionsAndShowCopyConfirmation() async throws {
        let assetDirectoryURL = try XCTUnwrap(LocalDocumentPanelAssetLocator.directoryURL())
        let bridgeReady = expectation(description: "Local document bridge becomes ready")
        let renderReady = expectation(description: "Read-mode document renders")
        let actionsReceived = XCTestExpectation(description: "Copy and Open reach the native bridge")
        actionsReceived.expectedFulfillmentCount = 2
        actionsReceived.assertForOverFulfill = true
        let handler = LocalDocumentActionMessageHandler(
            bridgeReady: bridgeReady,
            renderReady: renderReady,
            actionsReceived: actionsReceived
        )
        let configuration = LocalDocumentPanelRuntime.makeWebViewConfiguration(for: .localOnly)
        configuration.userContentController.add(handler, name: "toasttyLocalDocumentPanel")
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        defer {
            webView.stopLoading()
            configuration.userContentController.removeScriptMessageHandler(forName: "toasttyLocalDocumentPanel")
        }
        webView.loadFileURL(
            assetDirectoryURL.appendingPathComponent("index.html"),
            allowingReadAccessTo: assetDirectoryURL
        )
        await fulfillment(of: [bridgeReady], timeout: 5)

        // A synthetic backing path enables the controls without reading a file or opening another app.
        let bootstrap = LocalDocumentPanelBootstrap(
            filePath: "/tmp/toastty-action-tests/readme.md",
            displayName: "readme.md",
            content: "# Document actions",
            contentRevision: 1,
            isEditing: false,
            isDirty: false,
            hasExternalConflict: false,
            isSaving: false,
            saveErrorMessage: nil,
            theme: .light,
            textScale: 1
        )
        let bootstrapScript = try XCTUnwrap(LocalDocumentPanelRuntime.bootstrapJavaScript(for: bootstrap))
        _ = try await webView.evaluateJavaScript(bootstrapScript)
        await fulfillment(of: [renderReady], timeout: 5)
        XCTAssertTrue(handler.actions.isEmpty)

        let result = try await webView.callAsyncJavaScript(
            """
            const copy = document.querySelector('button[aria-label="Copy Full Path"]');
            const open = document.querySelector('button[aria-label="Open in Default App"]');
            if (!copy || !open || copy.disabled || open.disabled) {
              throw new Error("Expected enabled read-mode action buttons");
            }
            const copyStatus = () => copy.parentElement.querySelector('[role="status"]');
            function waitForDOM(read, timeoutMs, message) {
              return new Promise((resolve, reject) => {
                const observer = new MutationObserver(inspect);
                const timeout = setTimeout(() => {
                  observer.disconnect();
                  reject(new Error(message));
                }, timeoutMs);
                function inspect() {
                  const value = read();
                  if (!value) return;
                  observer.disconnect();
                  clearTimeout(timeout);
                  resolve(value);
                }
                observer.observe(document.body, { childList: true, subtree: true, attributes: true });
                inspect();
              });
            }
            const initialCopyTitle = copy.title;
            const confirmationShown = waitForDOM(() => {
              const status = copyStatus();
              return status && {
                copyTitle: copy.title,
                openTitle: open.title,
                confirmation: status.textContent.trim(),
                live: status.getAttribute('aria-live')
              };
            }, 3000, "Copy confirmation did not render");
            copy.click();
            open.click();
            const confirmation = await confirmationShown;
            // The confirmation clears itself after 1.5 seconds.
            const dismissedCopyTitle = await waitForDOM(
              () => !copyStatus() && copy.title,
              5000,
              "Copy confirmation did not dismiss"
            );
            return { initialCopyTitle, ...confirmation, dismissedCopyTitle };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let feedback = try XCTUnwrap(result as? [String: String], "Expected string-valued copy confirmation fields")
        XCTAssertEqual(feedback, [
            "initialCopyTitle": "Copy Full Path",
            "copyTitle": "Path Copied",
            "openTitle": "Open in Default App",
            "confirmation": "Full path copied",
            "live": "polite",
            "dismissedCopyTitle": "Copy Full Path",
        ])
        await fulfillment(of: [actionsReceived], timeout: 5)
        XCTAssertEqual(handler.actions, [["type": "copyFullPath"], ["type": "openInDefaultApp"]])
    }
}

@MainActor
private final class LocalDocumentActionMessageHandler: NSObject, WKScriptMessageHandler {
    private var bridgeReady: XCTestExpectation?
    private var renderReady: XCTestExpectation?
    private let actionsReceived: XCTestExpectation?
    private(set) var actions: [[String: String]] = []

    init(bridgeReady: XCTestExpectation, renderReady: XCTestExpectation, actionsReceived: XCTestExpectation? = nil) {
        self.bridgeReady = bridgeReady
        self.renderReady = renderReady
        self.actionsReceived = actionsReceived
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "bridgeReady":
            bridgeReady?.fulfill()
            bridgeReady = nil
        case "renderReady":
            guard (body["contentRevision"] as? Int) == 1,
                  (body["displayName"] as? String) == "readme.md",
                  (body["isEditing"] as? Bool) == false else { return }
            renderReady?.fulfill()
            renderReady = nil
        case "copyFullPath", "openInDefaultApp":
            if let action = body as? [String: String] {
                actions.append(action)
            } else {
                XCTFail("Expected a string-valued action payload for \(type)")
            }
            actionsReceived?.fulfill()
        default:
            break
        }
    }
}
