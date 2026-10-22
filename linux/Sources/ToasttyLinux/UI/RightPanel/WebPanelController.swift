import CGtk
import CWebKitGtk
import CoreState
import Foundation

/// One live web panel (browser, local document, Scratchpad): a GTK widget
/// tree around a `WebKitWebView`. `WebPanelHost` creates one per panel ID
/// and keeps it for the panel's lifetime, so the same widget moves between
/// the right panel and splits.
@MainActor
public class WebPanelController {
    public let panelID: UUID
    public let root: WidgetPtr
    private let rootRef: GObjectRef
    public let webViewWidget: WidgetPtr
    let webView: UnsafeMutablePointer<WebKitWebView>
    let contentManager: OpaquePointer
    let services: any WebPanelServices
    public internal(set) var webState: WebPanelState
    public internal(set) var windowID: UUID
    var isClosed = false

    public private(set) var decoration = PanelTabDecoration() {
        didSet { if decoration != oldValue { onDecorationChange?(panelID) } }
    }

    var onDecorationChange: ((UUID) -> Void)?

    /// Recent console/JS diagnostics from the page (automation, logs).
    public private(set) var diagnostics: [String] = []

    init(
        panelID: UUID,
        webState: WebPanelState,
        windowID: UUID,
        services: any WebPanelServices,
        session: OpaquePointer,
        settings: OpaquePointer,
        classes: [String]
    ) {
        self.panelID = panelID
        self.webState = webState
        self.windowID = windowID
        self.services = services

        contentManager = webkit_user_content_manager_new()!
        let viewWidget = WebKitEnvironment.shared.makeWebView(session: session, contentManager: contentManager, settings: settings)
        g_object_unref(UnsafeMutableRawPointer(settings))
        webViewWidget = viewWidget
        webView = cast(viewWidget)
        Gtk.expand(viewWidget)

        root = Gtk.vbox(classes: ["web-panel", "panel-content"] + classes)
        rootRef = GObjectRef(sinking: root)
        Gtk.expand(root)
        Gtk.setName(root, "web-panel-\(panelID.uuidString)")

        let focus = gtk_event_controller_focus_new()!
        Signal.connect(focus, "enter") { [weak self] in
            guard let self, self.isClosed == false else { return }
            self.services.webPanelDidRequestFocus(panelID: self.panelID)
        }
        gtk_widget_add_controller(root, focus)
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(click), 0)
        gtk_event_controller_set_propagation_phase(cast(click), GTK_PHASE_CAPTURE)
        Signal.connectPress(click) { [weak self] _, _, _ in
            guard let self, self.isClosed == false else { return }
            self.services.webPanelWasClicked(panelID: self.panelID)
        }
        gtk_widget_add_controller(root, cast(click))

        Signal.connectUInt(viewWidget, "web-process-terminated") { [weak self] reason in
            self?.record("web process terminated (reason \(reason))")
            self?.webProcessTerminated()
        }
    }

    // MARK: Overridable behavior

    /// New panel state from the store.
    func update(_ webState: WebPanelState, windowID: UUID) {
        self.webState = webState
        self.windowID = windowID
    }

    /// Moves keyboard focus into the panel.
    func focusContent() {
        gtk_widget_grab_focus(webViewWidget)
    }

    /// Panel-scoped command (`find.*`, `browser.*`, `local-document.*`).
    func perform(commandID: String) -> Bool { false }

    /// The color scheme changed.
    func applyTheme(isDark: Bool) {}

    func webProcessTerminated() {}

    /// Unsaved work that needs a confirmation before closing.
    var closeConfirmationMessage: (heading: String, body: String)? { nil }

    /// Extra key/value facts for automation summaries.
    func automationFacts() -> [String: String] { [:] }

    func close() {
        guard isClosed == false else { return }
        isClosed = true
        webkit_web_view_stop_loading(webView)
        Gtk.detachFromParent(root)
    }

    // MARK: Helpers

    func setDecoration(icon: OpaquePointer?, isLoading: Bool) {
        decoration = PanelTabDecoration(icon: icon, isLoading: isLoading)
    }

    func record(_ diagnostic: String) {
        diagnostics.append(diagnostic)
        if diagnostics.count > 50 { diagnostics.removeFirst(diagnostics.count - 50) }
        if ProcessInfo.processInfo.environment["TOASTTY_LINUX_WEB_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[web \(panelID.uuidString.prefix(8))] \(diagnostic)\n".utf8))
        }
    }

    /// Registers `window.webkit.messageHandlers.<name>` (in `world`, or the
    /// page's main world) and delivers each message body as JSON.
    func registerMessageHandler(_ name: String, world: String? = nil, _ handler: @escaping @MainActor (String?) -> Void) {
        webkit_user_content_manager_register_script_message_handler(contentManager, name, world)
        Signal.connectPointer(contentManager, "script-message-received::\(name)") { value in
            handler(jsonString(fromJSCValue: value))
        }
    }

    func addUserScript(_ source: String, world: String? = nil, allFrames: Bool, atStart: Bool) {
        let frames = allFrames ? WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES : WEBKIT_USER_CONTENT_INJECT_TOP_FRAME
        let time = atStart ? WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START : WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END
        let script: OpaquePointer? = if let world {
            webkit_user_script_new_for_world(source, frames, time, world, nil, nil)
        } else {
            webkit_user_script_new(source, frames, time, nil, nil)
        }
        guard let script else { return }
        webkit_user_content_manager_add_script(contentManager, script)
        webkit_user_script_unref(script)
    }

    /// Runs JavaScript in the page; the completion gets the JSON result.
    public func evaluate(_ script: String, world: String? = nil, completion: @escaping @MainActor (Result<String?, WebJavaScriptError>) -> Void = { _ in }) {
        guard isClosed == false else {
            completion(.failure(.evaluation("panel closed")))
            return
        }
        WebJavaScript.evaluate(webView, script, world: world, completion: completion)
    }

    /// The URI the view shows.
    public var currentURI: String? {
        webkit_web_view_get_uri(webView).map { String(cString: $0) }
    }

    public var isLoading: Bool { webkit_web_view_is_loading(webView).bool }

    /// PNG of the visible page, or of the whole document
    /// (`webkit_web_view_get_snapshot`).
    public func snapshotPNG(fullDocument: Bool = false, completion: @escaping @MainActor (Data?) -> Void) {
        let box = Unmanaged.passRetained(SnapshotBox(completion)).toOpaque()
        let region = fullDocument ? WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT : WEBKIT_SNAPSHOT_REGION_VISIBLE
        webkit_web_view_get_snapshot(webView, region, WEBKIT_SNAPSHOT_OPTIONS_NONE, nil, snapshotCallback, box)
    }
}

private final class SnapshotBox: @unchecked Sendable {
    let completion: @MainActor (Data?) -> Void
    init(_ completion: @escaping @MainActor (Data?) -> Void) { self.completion = completion }
}

private let snapshotCallback: GAsyncReadyCallback = { source, result, data in
    let box = Unmanaged<SnapshotBox>.fromOpaque(data!).takeRetainedValue()
    var error: UnsafeMutablePointer<GError>?
    let texture = webkit_web_view_get_snapshot_finish(
        UnsafeMutableRawPointer(source!).assumingMemoryBound(to: WebKitWebView.self), result, &error
    )
    if let error { g_error_free(error) }
    let png = pngData(fromTexture: texture)
    if let texture { g_object_unref(UnsafeMutableRawPointer(texture)) }
    MainActor.assumeIsolated { box.completion(png) }
}

/// Placeholder for web panel kinds Linux does not render yet (diff).
@MainActor
final class UnsupportedWebPanelController: WebPanelController {
    init(panelID: UUID, webState: WebPanelState, windowID: UUID, services: any WebPanelServices) {
        super.init(
            panelID: panelID, webState: webState, windowID: windowID, services: services,
            session: WebKitEnvironment.shared.ephemeralSession,
            settings: WebKitEnvironment.settings(developerExtras: false), classes: ["unsupported-web-panel"]
        )
        let page = adw_status_page_new()!
        Gtk.expand(page)
        adw_status_page_set_icon_name(cast(page), "document-edit-symbolic")
        adw_status_page_set_title(cast(page), webState.title)
        adw_status_page_set_description(cast(page), "\(webState.definition.defaultTitle) panels are not available on Linux yet.")
        gtk_widget_set_focusable(page, 1)
        Gtk.append(root, page)
    }

    override func focusContent() {
        if let child = gtk_widget_get_first_child(root) { gtk_widget_grab_focus(child) }
    }
}
