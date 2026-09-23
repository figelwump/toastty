import AppKit
@testable import ToasttyApp
import WebKit
import XCTest

@MainActor
final class LocalDocumentPanelActionTests: XCTestCase {
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
    private let actionsReceived: XCTestExpectation
    private(set) var actions: [[String: String]] = []

    init(bridgeReady: XCTestExpectation, renderReady: XCTestExpectation, actionsReceived: XCTestExpectation) {
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
            actionsReceived.fulfill()
        default:
            break
        }
    }
}
