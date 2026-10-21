#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CWebKitGtk
import CoreState
import Foundation
import ToasttyAppLogic

// The WebKitGTK panels as the app-logic layer's web panel hosts
// (`LinuxBrowserPanelHost`, `LinuxLocalDocumentPanelHost`,
// `LinuxScratchpadPanelHost`), so the shared `WebPanelRuntimeRegistry` —
// and through it the automation socket (`panel.browser.*`,
// `panel.local_document.*`, `automation.*_panel_state`), focused-panel
// close confirmation and `AppURLRouter` — reach the live panels.
//
// Wiring (app-logic frontend bootstrap, after `installWebPanels()`):
//
//     app.webPanelHost?.attach(logic: logic)

extension WebPanelHost {
    /// Routes panel lifecycle and link opening through `LinuxAppLogic`.
    public func attach(logic: LinuxAppLogic) {
        guard let services = services as? StoreWebPanelServices else { return }
        LinuxAppLogic.installAnnotationScreenshotRenderer { request in
            try LinuxAnnotationScreenshotRenderer.render(request)
        }
        services.hooks.panelDidAttach = { [weak logic] panelID, controller in
            guard let logic else { return }
            switch controller {
            case let browser as BrowserPanelController:
                logic.attachBrowserHost(browser, panelID: panelID)
                browser.onNavigationCommitted = { [weak logic] url in logic?.browserDidCommitNavigation(panelID: panelID, url: url) }
                browser.onURIObserved = { [weak logic] url, isLoading in
                    logic?.browserDidObserveURL(panelID: panelID, url: url, isLoading: isLoading)
                }
                browser.onLoadEvent = { [weak logic] event in
                    logic?.browserNavigationDidChange(panelID: panelID, event: event.appLogicEvent)
                }
                browser.attachAnnotations(logic.browserAnnotationController(panelID: panelID))
            case let document as LocalDocumentPanelController: logic.attachLocalDocumentHost(document, panelID: panelID)
            case let scratchpad as ScratchpadPanelController: logic.attachScratchpadHost(scratchpad, panelID: panelID)
            default: break
            }
        }
        services.hooks.panelWillDetach = { [weak logic] panelID, controller in
            guard let logic else { return }
            switch controller {
            case is BrowserPanelController: logic.detachBrowserHost(panelID: panelID)
            case is LocalDocumentPanelController: logic.detachLocalDocumentHost(panelID: panelID)
            case is ScratchpadPanelController: logic.detachScratchpadHost(panelID: panelID)
            default: break
            }
        }
        services.hooks.metadataDidChange = { [weak logic, weak self] panelID, title, url in
            guard let logic, self?.controller(for: panelID) is BrowserPanelController else { return false }
            logic.browserDidUpdate(panelID: panelID, title: title, url: url)
            return true
        }
        services.hooks.openSecondaryURL = { [weak logic, weak self] url, panelID in
            // AppURLRouter (local file links with line numbers, directories,
            // external apps) is reached through the browser runtime.
            guard let logic, self?.controller(for: panelID) is BrowserPanelController else {
                return self?.fallbackOpenSecondary(url, panelID: panelID) ?? false
            }
            return logic.browserRequestsSecondaryOpen(panelID: panelID, url: url)
        }
        // Panels created before attaching.
        for (panelID, controller) in controllers {
            services.hooks.panelDidAttach?(panelID, controller)
        }
    }

    private func fallbackOpenSecondary(_ url: URL, panelID: UUID) -> Bool {
        guard let services = services as? StoreWebPanelServices else { return false }
        let hook = services.hooks.openSecondaryURL
        services.hooks.openSecondaryURL = nil
        defer { services.hooks.openSecondaryURL = hook }
        return services.openSecondaryURL(url, fromPanelID: panelID)
    }
}

extension LinuxAppController {
    /// Builds a web panel's content off screen (`LinuxBrowserHostMaterializer`):
    /// a panel that was never shown gets its controller, which attaches to
    /// app-logic and loads. Mounting it later reuses that controller, and it
    /// closes with the panel like any other.
    func materializeWebPanel(panelID: UUID) {
        guard hosts.livePanelIDs.contains(panelID) == false,
              let selection = store.state.workspaceSelection(containingPanelID: panelID),
              let panel = selection.workspace.allPanelsByID[panelID], case .web = panel else { return }
        let inRightPanel = selection.workspace.orderedTabs.contains { tab in
            tab.rightAuxPanel.orderedTabs.contains { $0.panelID == panelID }
        }
        _ = hosts.contentWidget(
            for: panelID, panel: panel, workspaceID: selection.workspaceID,
            windowID: selection.windowID, inRightPanel: inRightPanel
        )
    }
}

extension BrowserLoadEvent {
    var appLogicEvent: LinuxBrowserNavigationEvent {
        switch self {
        case .started: return .started
        case .finished: return .finished
        case .failed(let domain, let code, let message): return .failed(domain: domain, code: code, message: message)
        }
    }
}

extension BrowserPanelController: LinuxBrowserPanelHost {
    public func focus() -> Bool {
        focusContent()
        return true
    }

    public func synchronize(webState: WebPanelState) { update(webState, windowID: windowID) }
    public var isInWindow: Bool { gtk_widget_get_root(root) != nil }

    public func load(urlString: String) -> Bool { load(userInput: urlString) }
    public var canGoBack: Bool { webkit_web_view_can_go_back(webView).bool }
    public var canGoForward: Bool { webkit_web_view_can_go_forward(webView).bool }
    public var currentURLString: String? { currentURI }
    public var currentTitle: String? { webkit_web_view_get_title(webView).map { String(cString: $0) } }

    public var pageZoom: Double { webkit_web_view_get_zoom_level(webView) }

    public var viewportSize: CGSize {
        CGSize(width: Int(gtk_widget_get_width(webViewWidget)), height: Int(gtk_widget_get_height(webViewWidget)))
    }

    public func pageScrollOffset() async -> CGPoint? {
        await withCheckedContinuation { continuation in
            evaluate("({x: window.scrollX || document.documentElement.scrollLeft || 0, y: window.scrollY || document.documentElement.scrollTop || 0})") { result in
                guard case .success(let json?) = result, let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let x = (object["x"] as? NSNumber)?.doubleValue, let y = (object["y"] as? NSNumber)?.doubleValue else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: CGPoint(x: x, y: y))
            }
        }
    }

    public var faviconPNG: Data? {
        pngData(fromTexture: webkit_web_view_get_favicon(webView))
    }

    public func captureScreenshotPNG() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            snapshotPNG { data in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: WebJavaScriptError.evaluation("snapshot failed"))
                }
            }
        }
    }
}

extension LocalDocumentPanelController: LinuxLocalDocumentPanelHost {
    public func focus() -> Bool {
        focusContent()
        return true
    }

    public var closeConfirmation: LinuxLocalDocumentCloseConfirmation? {
        guard let session, session.needsCloseConfirmation else { return nil }
        return session.isSaving
            ? .saveInProgress(displayName: session.displayName)
            : .dirtyDraft(displayName: session.displayName)
    }
}

extension ScratchpadPanelController: LinuxScratchpadPanelHost {
    public func focus() -> Bool {
        focusContent()
        return true
    }
}
#endif
