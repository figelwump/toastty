import CGtk
import CWebKitGtk
import CoreState
import Foundation

/// Scratchpad panel: the generated `scratchpad-panel` bundle (served as
/// `toastty://scratchpad/`) rendering the panel's stored HTML document in its
/// sandboxed iframe. Bootstrap delivery over `toasttyScratchpadPanel`;
/// trusted http(s) link clicks reach native through
/// `toasttyScratchpadExternalLink` in an isolated script world (generated
/// HTML cannot post to it), and open a right-panel browser tab. A new
/// document revision in state reloads the bootstrap.
@MainActor
public final class ScratchpadPanelController: WebPanelController {
    public private(set) var currentBootstrap: ScratchpadPanelBootstrap?
    public private(set) var isBridgeReady = false
    public private(set) var renderedRevision: Int?
    private var pendingBootstrapScript: String?
    private var theme: ScratchpadPanelTheme

    nonisolated static let entryURI = "toastty://scratchpad/index.html"

    init(panelID: UUID, webState: WebPanelState, windowID: UUID, services: any WebPanelServices) {
        theme = LinuxTheme.isDark ? .dark : .light
        super.init(
            panelID: panelID, webState: webState, windowID: windowID, services: services,
            session: WebKitEnvironment.shared.ephemeralSession,
            settings: WebKitEnvironment.settings(developerExtras: WebKitEnvironment.developerExtrasEnabled),
            classes: ["scratchpad-panel"]
        )
        Gtk.append(root, webViewWidget)

        registerMessageHandler(ScratchpadBridgeScript.handlerName) { [weak self] json in
            guard let self, let json, let data = json.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.handle(body)
        }
        registerMessageHandler(ScratchpadBridgeScript.externalLinkHandlerName, world: ScratchpadBridgeScript.externalLinkWorldName) { [weak self] json in
            guard let self else { return }
            let body = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) as? String }
            guard let url = ScratchpadBridgeScript.externalLinkURL(fromMessage: body) else { return }
            _ = self.services.openSecondaryURL(url, fromPanelID: self.panelID)
        }
        addUserScript(ScratchpadBridgeScript.externalLinkJavaScript, world: ScratchpadBridgeScript.externalLinkWorldName, allFrames: true, atStart: true)
        WebSignal.decidePolicy(webViewWidget) { decision, type in
            guard type != WEBKIT_POLICY_DECISION_TYPE_RESPONSE.rawValue,
                  let action = webkit_navigation_policy_decision_get_navigation_action(cast(decision)) else { return false }
            let uri = webkit_navigation_action_get_request(action).flatMap { webkit_uri_request_get_uri($0) }.map { String(cString: $0) } ?? ""
            if Self.allowsNavigation(to: uri) { return false }
            webkit_policy_decision_ignore(cast(decision))
            return true
        }
        reloadBootstrap()
        webkit_web_view_load_uri(webView, Self.entryURI)
    }

    /// The bundle page itself and its `about:srcdoc` content frame only.
    nonisolated static func allowsNavigation(to uri: String) -> Bool {
        uri.hasPrefix("about:") || uri == entryURI || uri == "toastty://scratchpad/" || uri.hasPrefix(entryURI + "#")
    }

    private func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "bridgeReady":
            // A fresh page: (re)deliver the current bootstrap.
            isBridgeReady = true
            pendingBootstrapScript = currentBootstrap?.deliveryJavaScript()
            pushBootstrap()
        case "renderReady":
            renderedRevision = (body["revision"] as? Int) ?? (body["revision"] as? Double).map(Int.init)
        case "consoleMessage":
            record("console.\(body["level"] as? String ?? "info"): \(body["message"] as? String ?? "")")
        case "javascriptError":
            record("js error: \(body["message"] as? String ?? "")")
        case "unhandledRejection":
            record("unhandled rejection: \(body["reason"] as? String ?? "")")
        case "cspViolation":
            record("csp: \(body["violatedDirective"] as? String ?? "") \(body["blockedURI"] as? String ?? "")")
        default:
            break
        }
    }

    func reloadBootstrap() {
        let bootstrap = ScratchpadPanelBootstrap.make(webState: webState, theme: theme) { [services] id in
            try services.scratchpadDocument(documentID: id)
        }
        currentBootstrap = bootstrap
        pendingBootstrapScript = bootstrap.deliveryJavaScript()
        if bootstrap.displayName != webState.title {
            services.webPanelMetadataDidChange(panelID: panelID, title: bootstrap.displayName, url: nil)
        }
        pushBootstrap()
    }

    private func pushBootstrap() {
        guard isBridgeReady, let script = pendingBootstrapScript else { return }
        evaluate(script) { [weak self] result in
            guard let self else { return }
            if case .success(let value) = result, WebJavaScript.bool(value), self.pendingBootstrapScript == script {
                self.pendingBootstrapScript = nil
            }
        }
    }

    override func update(_ webState: WebPanelState, windowID: UUID) {
        let previous = self.webState.scratchpad
        super.update(webState, windowID: windowID)
        if previous?.revision != webState.scratchpad?.revision || previous?.documentID != webState.scratchpad?.documentID {
            reloadBootstrap()
        }
    }

    override func applyTheme(isDark: Bool) {
        let next: ScratchpadPanelTheme = isDark ? .dark : .light
        guard next != theme else { return }
        theme = next
        reloadBootstrap()
    }

    override func focusContent() {
        gtk_widget_grab_focus(webViewWidget)
        if isBridgeReady { evaluate(ScratchpadBridgeScript.focusActiveContent) }
    }

    override func automationFacts() -> [String: String] {
        [
            "kind": "scratchpad",
            "title": currentBootstrap?.displayName ?? "",
            "bridgeReady": "\(isBridgeReady)",
            "documentID": currentBootstrap?.documentID?.uuidString ?? "",
            "revision": "\(currentBootstrap?.revision ?? -1)",
            "renderedRevision": "\(renderedRevision ?? -1)",
            "missingDocument": "\(currentBootstrap?.missingDocument ?? true)",
            "theme": theme.rawValue,
        ]
    }

    /// Public entry for the app-logic seam (`LinuxScratchpadPanelHost.reloadDocument`).
    public func reloadDocument() { reloadBootstrap() }
}
