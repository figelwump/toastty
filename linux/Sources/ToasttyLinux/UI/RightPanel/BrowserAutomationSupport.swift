#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CWebKitGtk
import Foundation
import ToasttyAppLogic

/// What `toastty browser console|network|dialog` reads for one browser
/// panel: console messages and uncaught errors (a main-world user script
/// posting to `toasttyConsole`), resource loads (`resource-load-started`),
/// and JavaScript dialogs answered by the automation policy.
@MainActor
final class BrowserAutomationRecorder {
    static let entryLimit = 1000
    static let messageHandlerName = "toasttyConsole"

    private(set) var console: [LinuxBrowserConsoleEntry] = []
    private(set) var network: [LinuxBrowserNetworkEntry] = []
    private(set) var inFlight = 0
    var dialogPolicy: LinuxBrowserDialogPolicy?
    private var nextSequence = 1

    static let consoleScript = #"""
    (() => {
      if (window.__toasttyConsoleInstalled) return;
      window.__toasttyConsoleInstalled = true;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.toasttyConsole;
      if (!handler) return;
      const format = (value) => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return value.stack ? value.name + ': ' + value.message + '\n' + value.stack : value.name + ': ' + value.message;
        try { const json = JSON.stringify(value); return json === undefined ? String(value) : json; } catch (e) { return String(value); }
      };
      const post = (level, args) => {
        try { handler.postMessage({ level, text: Array.from(args, format).join(' ').slice(0, 10000), url: location.href }); } catch (e) {}
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug', 'trace']) {
        const original = console[level];
        if (typeof original !== 'function') continue;
        console[level] = function (...args) { post(level === 'trace' ? 'debug' : level, args); return original.apply(this, args); };
      }
      const assert = console.assert;
      console.assert = function (condition, ...args) { if (!condition) post('error', ['Assertion failed:', ...args]); return assert.apply(this, [condition, ...args]); };
      window.addEventListener('error', (event) => {
        if (event.error) { post('pageerror', [event.error]); return; }
        if (event.message) post('pageerror', [event.message + (event.filename ? ' (' + event.filename + ':' + event.lineno + ')' : '')]);
      });
      window.addEventListener('unhandledrejection', (event) => post('pageerror', ['Unhandled promise rejection:', event.reason]));
    })();
    """#

    func install(on controller: BrowserPanelController) {
        controller.registerMessageHandler(Self.messageHandlerName) { [weak self] json in
            guard let self, let json, let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.appendConsole(level: object["level"] as? String ?? "log", text: object["text"] as? String ?? "", url: object["url"] as? String)
        }
        controller.addUserScript(Self.consoleScript, allFrames: true, atStart: true)
        // Keeps the automation world (and the element refs in it) alive
        // between `toastty browser` calls.
        controller.addUserScript("void 0;", world: LinuxBrowserAutomationScript.worldName, allFrames: false, atStart: true)

        WebSignal.resourceLoadStarted(controller.webViewWidget) { [weak self] resource, request in
            self?.track(resource: resource, request: request)
        }
        Signal.connectPointerBool(controller.webViewWidget, "script-dialog") { [weak self] dialog in
            guard let self, let dialog else { return false }
            return self.answer(OpaquePointer(dialog), pageURL: controller.currentURI)
        }
    }

    func clearConsole() { console.removeAll() }
    func clearNetwork() { network.removeAll(where: \.isFinished) }

    private func sequence() -> Int {
        defer { nextSequence += 1 }
        return nextSequence
    }

    private func appendConsole(level: String, text: String, url: String?) {
        console.append(LinuxBrowserConsoleEntry(sequence: sequence(), level: level, text: text, url: url, date: Date()))
        if console.count > Self.entryLimit { console.removeFirst(console.count - Self.entryLimit) }
    }

    private func track(resource: OpaquePointer, request: OpaquePointer) {
        let method = webkit_uri_request_get_http_method(request).map { String(cString: $0) } ?? "GET"
        var url = webkit_uri_request_get_uri(request).map { String(cString: $0) } ?? ""
        if url.count > 2000 { url = String(url.prefix(2000)) + "…" }
        let entrySequence = sequence()
        network.append(LinuxBrowserNetworkEntry(sequence: entrySequence, method: method, url: url, startedAt: Date()))
        if network.count > Self.entryLimit { network.removeFirst(network.count - Self.entryLimit) }
        inFlight += 1
        Signal.connectPointer(resource, "failed") { [weak self] error in
            let message = error.map { String(cString: $0.assumingMemoryBound(to: GError.self).pointee.message) } ?? "failed"
            self?.update(entrySequence) { $0.error = message }
        }
        Signal.connect(resource, "finished") { [weak self] in
            guard let self else { return }
            self.inFlight = max(0, self.inFlight - 1)
            self.update(entrySequence) { entry in
                entry.isFinished = true
                entry.finishedAt = Date()
                if let response = webkit_web_resource_get_response(resource) {
                    let status = Int(webkit_uri_response_get_status_code(response))
                    entry.status = status == 0 ? nil : status
                    entry.mimeType = webkit_uri_response_get_mime_type(response).map { String(cString: $0) }
                }
            }
        }
    }

    private func update(_ entrySequence: Int, _ change: (inout LinuxBrowserNetworkEntry) -> Void) {
        guard let index = network.lastIndex(where: { $0.sequence == entrySequence }) else { return }
        change(&network[index])
    }

    /// Answers a dialog by the policy (when automation set one) and records
    /// it; without a policy WebKit shows the dialog.
    private func answer(_ dialog: OpaquePointer, pageURL: String?) -> Bool {
        guard let policy = dialogPolicy else { return false }
        let message = webkit_script_dialog_get_message(dialog).map { String(cString: $0) } ?? ""
        let type = webkit_script_dialog_get_dialog_type(dialog)
        let kind: String
        var outcome = policy.accept ? "accepted" : "dismissed"
        switch type {
        case WEBKIT_SCRIPT_DIALOG_ALERT:
            kind = "alert"
            outcome = "closed"
        case WEBKIT_SCRIPT_DIALOG_CONFIRM:
            kind = "confirm"
            webkit_script_dialog_confirm_set_confirmed(dialog, policy.accept.gboolean)
        case WEBKIT_SCRIPT_DIALOG_PROMPT:
            kind = "prompt"
            if policy.accept {
                let text = policy.promptText
                    ?? webkit_script_dialog_prompt_get_default_text(dialog).map { String(cString: $0) } ?? ""
                webkit_script_dialog_prompt_set_text(dialog, text)
                outcome = "accepted with \"\(text)\""
            }
        default:
            kind = "beforeunload"
            webkit_script_dialog_confirm_set_confirmed(dialog, policy.accept.gboolean)
        }
        appendConsole(level: "dialog", text: "\(kind) \"\(message)\" \(outcome)", url: pageURL)
        return true
    }
}

extension BrowserPanelController: LinuxBrowserAutomationHost {
    public func callAutomationFunction(_ body: String, world: String?) async throws -> String? {
        guard isClosed == false else { throw WebJavaScriptError.evaluation("panel closed") }
        return try await withCheckedThrowingContinuation { continuation in
            WebJavaScript.callAsync(webView, body, world: world) { result in
                continuation.resume(with: result)
            }
        }
    }

    public func captureAutomationScreenshotPNG(fullPage: Bool) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            snapshotPNG(fullDocument: fullPage) { data in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: WebJavaScriptError.evaluation("WebKit returned no snapshot"))
                }
            }
        }
    }

    public var automationConsole: [LinuxBrowserConsoleEntry] { automation.console }
    public func clearAutomationConsole() { automation.clearConsole() }
    public var automationNetwork: [LinuxBrowserNetworkEntry] { automation.network }
    public var automationRequestsInFlight: Int { automation.inFlight }
    public func clearAutomationNetwork() { automation.clearNetwork() }
    public var automationDialogPolicy: LinuxBrowserDialogPolicy? {
        get { automation.dialogPolicy }
        set { automation.dialogPolicy = newValue }
    }
}
#endif
