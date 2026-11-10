import CGtk
import CWebKitGtk
import CWebKitShim
import CoreState
import Foundation
#if TOASTTY_LINUX_APP_LOGIC
import ToasttyAppLogic
#endif

/// WebKitGTK browser panel: navigation toolbar with a location entry,
/// progress bar, page zoom from `WebPanelState.browserPageZoom`, title /
/// URL persisted through `updateWebPanelMetadata`, favicon and loading state
/// on the tab, Toastty link routing (Ctrl/middle click and `target=_blank`
/// open a new right-panel tab; non-web schemes leave the browser), popup
/// capture, downloads to the XDG Downloads directory, the `toastty://`
/// Getting Started page with its native actions, annotation mode
/// (`BrowserAnnotationOverlay`, attached by the app-logic bridge), and mouse
/// back/forward buttons running Toastty's navigation history like macOS's
/// `NavigationMouseInterceptor`.
@MainActor
public final class BrowserPanelController: WebPanelController {
    private let toolbar: WidgetPtr
    private let backButton: WidgetPtr
    private let forwardButton: WidgetPtr
    private let reloadButton: WidgetPtr
    private let entry: WidgetPtr
    private let zoomButton: WidgetPtr
    private let progress: WidgetPtr
    /// The `GtkOverlay` holding the web view, progress bar, and annotation layers.
    private var contentOverlay: WidgetPtr?
    private var pageMenuButton: WidgetPtr?
    #if TOASTTY_LINUX_APP_LOGIC
    private(set) var annotation: BrowserAnnotationOverlay?
    #endif
    /// App-logic callbacks: a main-frame navigation committed, and the URI
    /// changed (`isLoading` true while a load is in flight).
    var onNavigationCommitted: ((String?) -> Void)?
    var onURIObserved: ((String?, Bool) -> Void)?
    /// Main-frame navigation results for `panel.browser.state`. Internal
    /// pages (start page, invalid URL) and superseded loads are not reported.
    var onLoadEvent: ((BrowserLoadEvent) -> Void)?
    /// The in-flight load is an internal page (`webkit_web_view_load_html`).
    private var internalLoadPending = false
    private var loadIsInternal = false
    /// The user stopped the load: WebKit's cancellation is then the result.
    private var stopRequested = false
    private var lastRequestedURLString: String?
    private var isShowingStartPage = false
    private var appliedZoom: Double = 1
    private var popupCaptures: [ObjectIdentifier: GObjectRef] = [:]
    private var lastPublished: (title: String?, url: String?)?
    public private(set) var lastNavigationError: String?

    init(panelID: UUID, webState: WebPanelState, windowID: UUID, services: any WebPanelServices) {
        let settings = WebKitEnvironment.settings(developerExtras: WebKitEnvironment.developerExtrasEnabled)
        webkit_settings_set_enable_developer_extras(settings, 1)
        toolbar = Gtk.hbox(spacing: 4, classes: ["browser-toolbar", "toolbar"])
        backButton = Gtk.iconButton("go-previous-symbolic", tooltip: "Back")
        forwardButton = Gtk.iconButton("go-next-symbolic", tooltip: "Forward")
        reloadButton = Gtk.iconButton("view-refresh-symbolic", tooltip: "Reload (Ctrl+R)")
        entry = gtk_entry_new()!
        zoomButton = Gtk.button("100%", classes: ["flat", "browser-zoom"])
        progress = gtk_progress_bar_new()!
        super.init(
            panelID: panelID, webState: webState, windowID: windowID, services: services,
            session: WebKitEnvironment.shared.browserSession, settings: settings, classes: ["browser-panel"]
        )
        buildChrome()
        connectWebView()
        installKeys()
        installNavigationMouseButtons()
        WebDownloads.shared.watch(session: WebKitEnvironment.shared.browserSession)
        synchronize(with: webState)
        applyZoom(webState.effectiveBrowserPageZoom)
    }

    // MARK: Layout

    private func buildChrome() {
        Gtk.margins(toolbar, top: 4, bottom: 4, start: 6, end: 6)
        gtk_widget_set_sensitive(backButton, 0)
        gtk_widget_set_sensitive(forwardButton, 0)
        gtk_widget_set_hexpand(entry, 1)
        gtk_entry_set_placeholder_text(cast(entry), "Search or enter address")
        gtk_entry_set_input_purpose(cast(entry), GTK_INPUT_PURPOSE_URL)
        gtk_entry_set_icon_from_icon_name(cast(entry), GTK_ENTRY_ICON_PRIMARY, "web-browser-symbolic")
        Gtk.setName(entry, "browser-location")
        gtk_widget_set_tooltip_text(zoomButton, "Reset Zoom (Ctrl+0)")
        Gtk.setVisible(zoomButton, false)

        let menu = g_menu_new()!
        g_menu_append(menu, "Open in Default Browser", "browser-panel.open-external")
        g_menu_append(menu, "Copy Link", "browser-panel.copy-url")
        let devSection = g_menu_new()!
        g_menu_append(devSection, "Inspect Page", "browser-panel.inspect")
        g_menu_append_section(menu, nil, cast(devSection))
        g_object_unref(UnsafeMutableRawPointer(devSection))
        let menuButton = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(cast(menuButton), "view-more-symbolic")
        gtk_widget_add_css_class(menuButton, "flat")
        gtk_widget_set_tooltip_text(menuButton, "Page Menu")
        gtk_menu_button_set_menu_model(cast(menuButton), cast(menu))
        g_object_unref(UnsafeMutableRawPointer(menu))
        pageMenuButton = menuButton

        for child in [backButton, forwardButton, reloadButton, entry, zoomButton, menuButton] {
            Gtk.append(toolbar, child)
        }
        Gtk.append(root, toolbar)

        let overlay = gtk_overlay_new()!
        Gtk.expand(overlay)
        gtk_overlay_set_child(cast(overlay), webViewWidget)
        gtk_widget_add_css_class(progress, "osd")
        gtk_widget_set_valign(progress, GTK_ALIGN_START)
        gtk_widget_set_hexpand(progress, 1)
        gtk_widget_set_can_target(progress, 0)
        Gtk.setVisible(progress, false)
        gtk_overlay_add_overlay(cast(overlay), progress)
        Gtk.append(root, overlay)
        contentOverlay = overlay

        Signal.connect(backButton, "clicked") { [weak self] in _ = self?.goBack() }
        Signal.connect(forwardButton, "clicked") { [weak self] in _ = self?.goForward() }
        Signal.connect(reloadButton, "clicked") { [weak self] in _ = self?.reloadOrStop() }
        Signal.connect(zoomButton, "clicked") { [weak self] in
            guard let self else { return }
            self.services.send(.resetBrowserPanelPageZoom(panelID: self.panelID))
        }
        Signal.connect(entry, "activate") { [weak self] in
            guard let self else { return }
            let text = String(cString: gtk_editable_get_text(cast(self.entry)))
            if self.load(userInput: text) { gtk_widget_grab_focus(self.webViewWidget) }
        }

        let actions = g_simple_action_group_new()!
        func add(_ name: String, _ body: @escaping @MainActor () -> Void) {
            let action = g_simple_action_new(name, nil)!
            Signal.connectPointer(action, "activate") { _ in body() }
            g_action_map_add_action(cast(actions), cast(action))
            g_object_unref(UnsafeMutableRawPointer(action))
        }
        add("open-external") { [weak self] in
            guard let self, let uri = self.currentURI, let url = URL(string: uri) else { return }
            _ = self.services.openExternally(url, parent: self.root)
        }
        add("copy-url") { [weak self] in
            guard let self, let uri = self.currentURI else { return }
            self.services.copyToClipboard(uri)
            DesktopLauncher.toast("Link copied", from: self.root)
        }
        add("inspect") { [weak self] in
            guard let self else { return }
            if let inspector = webkit_web_view_get_inspector(self.webView) { webkit_web_inspector_show(inspector) }
        }
        gtk_widget_insert_action_group(root, "browser-panel", cast(actions))
        g_object_unref(UnsafeMutableRawPointer(actions))
    }

    private func installKeys() {
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        Signal.connectKeyPressed(keys) { [weak self] keyval, _, state in
            guard let self else { return false }
            let mods = state.rawValue & (GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue)
            let key = Int32(keyval)
            if mods == GDK_CONTROL_MASK.rawValue, key == GDK_KEY_l || key == GDK_KEY_L {
                self.focusLocationField()
                return true
            }
            if (mods == GDK_CONTROL_MASK.rawValue && (key == GDK_KEY_r || key == GDK_KEY_R)) || (mods == 0 && key == GDK_KEY_F5) {
                _ = self.reload()
                return true
            }
            if mods == 0, key == GDK_KEY_Escape, gtk_widget_has_focus(self.entryText).bool || gtk_widget_has_focus(self.entry).bool {
                self.resetLocationField()
                gtk_widget_grab_focus(self.webViewWidget)
                return true
            }
            if mods == GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue, key == GDK_KEY_a || key == GDK_KEY_A {
                return self.toggleAnnotationMode()
            }
            #if TOASTTY_LINUX_APP_LOGIC
            if mods == 0, key == GDK_KEY_Escape, let annotation = self.annotation, annotation.handleEscape() {
                return true
            }
            #endif
            return false
        }
        gtk_widget_add_controller(root, keys)
    }

    /// Mouse buttons 8/9 (back/forward) run Toastty's navigation history,
    /// as macOS's `NavigationMouseInterceptor` does for every window: the
    /// capture-phase gesture claims the whole press, so WebKit never sees it
    /// and the release cannot leak into the page.
    private func installNavigationMouseButtons() {
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(click), 0)
        gtk_event_controller_set_propagation_phase(click, GTK_PHASE_CAPTURE)
        Signal.connectPress(click) { [weak self] _, _, _ in
            guard let self else { return }
            let button = gtk_gesture_single_get_current_button(cast(click))
            guard let commandID = Self.navigationCommand(forMouseButton: button) else {
                gtk_gesture_set_state(cast(click), GTK_EVENT_SEQUENCE_DENIED)
                return
            }
            gtk_gesture_set_state(cast(click), GTK_EVENT_SEQUENCE_CLAIMED)
            self.services.runCommand(commandID, from: self.root)
        }
        gtk_widget_add_controller(root, click)
    }

    /// GDK button numbers: 8 = back, 9 = forward (X11/evdev convention).
    nonisolated static func navigationCommand(forMouseButton button: UInt32) -> String? {
        switch button {
        case 8: "navigation.back"
        case 9: "navigation.forward"
        default: nil
        }
    }

    // MARK: Annotation mode

    #if TOASTTY_LINUX_APP_LOGIC
    /// Adds the annotation overlay, mode bar and toolbar buttons.
    func attachAnnotations(_ controller: LinuxWebPanelAnnotationController) {
        guard annotation == nil, let contentOverlay else { return }
        let annotation = BrowserAnnotationOverlay(controller: controller, panel: self)
        gtk_overlay_add_overlay(cast(contentOverlay), annotation.area)
        gtk_overlay_add_overlay(cast(contentOverlay), annotation.modeBar)
        if let pageMenuButton {
            gtk_widget_insert_before(annotation.headerGroup, toolbar, pageMenuButton)
        } else {
            Gtk.append(toolbar, annotation.headerGroup)
        }
        self.annotation = annotation
    }
    #endif

    /// A page is loaded (not the start page), so it can be annotated.
    var canAnnotate: Bool {
        guard isShowingStartPage == false, let uri = currentURI else { return false }
        return uri.isEmpty == false && uri != "about:blank"
    }

    @discardableResult
    func toggleAnnotationMode() -> Bool {
        #if TOASTTY_LINUX_APP_LOGIC
        guard let annotation else { return false }
        guard canAnnotate || annotation.controller.isAnnotationModeEnabled else { return false }
        annotation.controller.toggleAnnotationMode()
        return true
        #else
        return false
        #endif
    }

    /// The entry's inner `GtkText` (focus lands there).
    private var entryText: WidgetPtr { gtk_widget_get_first_child(entry) ?? entry }

    // MARK: WebKit signals

    private func connectWebView() {
        Signal.notify(webViewWidget, "uri") { [weak self] in self?.uriChanged() }
        Signal.notify(webViewWidget, "title") { [weak self] in self?.publishMetadata() }
        Signal.notify(webViewWidget, "is-loading") { [weak self] in self?.loadingChanged() }
        Signal.notify(webViewWidget, "favicon") { [weak self] in self?.refreshDecoration() }
        Signal.notify(webViewWidget, "estimated-load-progress") { [weak self] in
            guard let self else { return }
            gtk_progress_bar_set_fraction(cast(self.progress), webkit_web_view_get_estimated_load_progress(self.webView))
        }
        Signal.connectUInt(webViewWidget, "load-changed") { [weak self] event in
            guard let self else { return }
            if event == WEBKIT_LOAD_STARTED.rawValue {
                self.lastNavigationError = nil
                self.stopRequested = false
                self.loadIsInternal = self.internalLoadPending
                self.internalLoadPending = false
                if self.loadIsInternal == false { self.onLoadEvent?(.started) }
            }
            if event == WEBKIT_LOAD_COMMITTED.rawValue { self.onNavigationCommitted?(self.currentURI) }
            if event == WEBKIT_LOAD_FINISHED.rawValue {
                self.updateHistoryButtons()
                self.publishMetadata()
                self.applyZoom(self.webState.effectiveBrowserPageZoom, force: true)
                if self.loadIsInternal == false { self.onLoadEvent?(.finished) }
            }
        }
        WebSignal.loadFailed(webViewWidget) { [weak self] _, uri, error in
            guard let self else { return false }
            self.lastNavigationError = error?.message
            self.record("load failed \(uri ?? "?"): \(error?.message ?? "")")
            guard self.loadIsInternal == false, let error else { return false }
            if error.isCancellation {
                // A newer navigation superseded this one; it reports itself.
                guard self.stopRequested else { return false }
                self.onLoadEvent?(.failed(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue, message: "cancelled"))
                return false
            }
            self.onLoadEvent?(.failed(domain: error.domain, code: error.code, message: error.message))
            // Returning false lets WebKit show its error page, a load of its
            // own; the failure stays the result.
            self.internalLoadPending = true
            return false
        }
        WebSignal.decidePolicy(webViewWidget) { [weak self] decision, type in
            self?.decidePolicy(decision, type: type) ?? false
        }
        WebSignal.create(webViewWidget) { [weak self] action in
            self?.createPopup(action)
        }
    }

    private func decidePolicy(_ decision: OpaquePointer, type: UInt32) -> Bool {
        if type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE.rawValue {
            let response: OpaquePointer = decision
            if webkit_response_policy_decision_is_mime_type_supported(cast(response)).bool == false,
               webkit_response_policy_decision_is_main_frame_main_resource(cast(response)).bool {
                webkit_policy_decision_download(cast(decision))
                return true
            }
            return false
        }
        guard let action = webkit_navigation_policy_decision_get_navigation_action(cast(decision)) else { return false }
        let request = webkit_navigation_action_get_request(action)
        let uri = request.flatMap { webkit_uri_request_get_uri($0) }.map { String(cString: $0) }
        let url = uri.flatMap(URL.init(string:))
        let modifiers = webkit_navigation_action_get_modifiers(action)
        let button = webkit_navigation_action_get_mouse_button(action)
        let isLink = webkit_navigation_action_get_navigation_type(action) == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED
        let decisionResult = BrowserLinkRouting.decision(
            url: url,
            isLinkActivation: isLink,
            opensNewWindow: type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION.rawValue,
            ctrlOrMiddleClick: (modifiers & guint(GDK_CONTROL_MASK.rawValue)) != 0 || button == 2,
            sourceFrameURL: currentURI.flatMap(URL.init(string:)),
            sourceIsMainFrame: true
        )
        switch decisionResult {
        case .allow:
            return false
        case .openSecondary(let target):
            webkit_policy_decision_ignore(cast(decision))
            _ = services.openSecondaryURL(target, fromPanelID: panelID)
            return true
        case .dispatchAction(let gettingStarted):
            webkit_policy_decision_ignore(cast(decision))
            services.runCommand(gettingStarted.commandID, from: root)
            return true
        case .ignore:
            record("ignored unsupported Toastty page action \(uri ?? "")")
            webkit_policy_decision_ignore(cast(decision))
            return true
        }
    }

    /// `window.open` with no usable URL yet: an offscreen related view
    /// captures the first real navigation and hands it to the router.
    private func createPopup(_ action: OpaquePointer?) -> WidgetPtr? {
        let requested = action.flatMap { webkit_navigation_action_get_request(cast($0)) }
            .flatMap { webkit_uri_request_get_uri($0) }.map { String(cString: $0) }
        if let target = BrowserLinkRouting.popupCaptureURL(requested.flatMap(URL.init(string:))) {
            _ = services.openSecondaryURL(target, fromPanelID: panelID)
            return nil
        }
        let popup = toastty_webkit_web_view_new(nil, nil, nil, nil, webView)!
        let ref = GObjectRef(sinking: popup)
        let key = ObjectIdentifier(ref)
        popupCaptures[key] = ref
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, let ref = self.popupCaptures.removeValue(forKey: key) else { return }
            webkit_web_view_stop_loading(cast(ref.widgetPointer))
            // Release after WebKit finishes the signal emission.
            MainLoop.idle { _ = ref }
        }
        Signal.notify(popup, "uri") { [weak self] in
            guard let self else { return }
            let uri = webkit_web_view_get_uri(cast(popup)).map { String(cString: $0) }
            if let target = BrowserLinkRouting.popupCaptureURL(uri.flatMap(URL.init(string:))) {
                _ = self.services.openSecondaryURL(target, fromPanelID: self.panelID)
                finish()
            }
        }
        Signal.connect(popup, "close") { finish() }
        MainLoop.timeout(milliseconds: 10_000) { finish(); return false }
        return popup
    }

    // MARK: State

    override func update(_ webState: WebPanelState, windowID: UUID) {
        super.update(webState, windowID: windowID)
        synchronize(with: webState)
        applyZoom(webState.effectiveBrowserPageZoom)
    }

    /// macOS `synchronizeDisplayedContent`: loads `restorableURL` unless the
    /// view already shows it (metadata we published comes back as state).
    private func synchronize(with webState: WebPanelState) {
        let desired = webState.restorableURL
        if let desired {
            if desired == currentURI || desired == lastPublished?.url {
                lastRequestedURLString = desired
                isShowingStartPage = false
                return
            }
            guard desired != lastRequestedURLString else { return }
            lastRequestedURLString = desired
            isShowingStartPage = false
            loadURI(desired)
            return
        }
        lastRequestedURLString = nil
        guard isShowingStartPage == false else { return }
        isShowingStartPage = true
        loadInternalPage(Self.startPageHTML(isDark: LinuxTheme.isDark))
        resetLocationField()
    }

    private func loadInternalPage(_ html: String) {
        internalLoadPending = true
        webkit_web_view_load_html(webView, html, "about:blank")
    }

    private func loadURI(_ uri: String) {
        guard URL(string: uri) != nil else {
            loadInternalPage(Self.invalidURLHTML(uri))
            onLoadEvent?(.started)
            onLoadEvent?(.failed(domain: NSURLErrorDomain, code: URLError.badURL.rawValue, message: "unsupported URL"))
            return
        }
        // A load requested here is the result from now on, before WebKit's
        // asynchronous start.
        internalLoadPending = false
        onLoadEvent?(.started)
        webkit_web_view_load_uri(webView, uri)
        if gtk_widget_has_focus(entryText).bool == false {
            gtk_editable_set_text(cast(entry), uri)
        }
    }

    /// Location-bar input. Returns whether a load started.
    @discardableResult
    public func load(userInput: String) -> Bool {
        guard let normalized = BrowserLinkRouting.normalizedUserEnteredURLString(userInput) else { return false }
        lastRequestedURLString = normalized
        isShowingStartPage = false
        loadURI(normalized)
        return true
    }

    private func uriChanged() {
        onURIObserved?(currentURI, isLoading)
        if gtk_widget_has_focus(entryText).bool == false { resetLocationField() }
        updateHistoryButtons()
        publishMetadata()
        refreshDecoration()
        #if TOASTTY_LINUX_APP_LOGIC
        annotation?.pageStateChanged()
        #endif
    }

    private func loadingChanged() {
        let loading = isLoading
        gtk_button_set_icon_name(cast(reloadButton), loading ? "process-stop-symbolic" : "view-refresh-symbolic")
        gtk_widget_set_tooltip_text(reloadButton, loading ? "Stop" : "Reload (Ctrl+R)")
        Gtk.setVisible(progress, loading)
        updateHistoryButtons()
        refreshDecoration()
        if loading == false { publishMetadata() }
        #if TOASTTY_LINUX_APP_LOGIC
        annotation?.pageStateChanged()
        #endif
    }

    private func refreshDecoration() {
        let favicon = webkit_web_view_get_favicon(webView)
        setDecoration(icon: favicon, isLoading: isLoading)
    }

    private func updateHistoryButtons() {
        gtk_widget_set_sensitive(backButton, webkit_web_view_can_go_back(webView))
        gtk_widget_set_sensitive(forwardButton, webkit_web_view_can_go_forward(webView))
    }

    private func resetLocationField() {
        let uri = currentURI
        let shown = (uri == nil || uri == "about:blank") ? "" : uri!
        gtk_editable_set_text(cast(entry), shown)
    }

    /// Title and URL into state (`currentURL` restores the page on relaunch).
    private func publishMetadata() {
        guard isClosed == false else { return }
        guard let uri = currentURI, uri != "about:blank" else { return }
        let rawTitle = webkit_web_view_get_title(webView).map { String(cString: $0) }
        let title = WebPanelState.normalizedTitle(rawTitle)
        guard lastPublished?.title != title || lastPublished?.url != uri else { return }
        lastPublished = (title, uri)
        lastRequestedURLString = uri
        services.webPanelMetadataDidChange(panelID: panelID, title: title, url: uri)
    }

    private func applyZoom(_ zoom: Double, force: Bool = false) {
        let clamped = WebPanelState.clampedBrowserPageZoom(zoom)
        guard force || abs(clamped - appliedZoom) > WebPanelState.browserPageZoomComparisonEpsilon else { return }
        appliedZoom = clamped
        webkit_web_view_set_zoom_level(webView, clamped)
        gtk_button_set_label(cast(zoomButton), "\(Int((clamped * 100).rounded()))%")
        Gtk.setVisible(zoomButton, abs(clamped - 1) > WebPanelState.browserPageZoomComparisonEpsilon)
    }

    // MARK: Commands

    public func focusLocationField() {
        gtk_widget_grab_focus(entry)
        gtk_editable_select_region(cast(entry), 0, -1)
    }

    @discardableResult public func goBack() -> Bool {
        guard webkit_web_view_can_go_back(webView).bool else { return false }
        webkit_web_view_go_back(webView)
        return true
    }

    @discardableResult public func goForward() -> Bool {
        guard webkit_web_view_can_go_forward(webView).bool else { return false }
        webkit_web_view_go_forward(webView)
        return true
    }

    @discardableResult public func reload() -> Bool {
        if let desired = lastRequestedURLString, currentURI == nil || currentURI == "about:blank" {
            loadURI(desired)
        } else {
            webkit_web_view_reload(webView)
        }
        return true
    }

    @discardableResult public func reloadOrStop() -> Bool {
        if isLoading {
            stopRequested = true
            webkit_web_view_stop_loading(webView)
            return true
        }
        return reload()
    }

    /// `panel.browser.reload`: always navigates to `urlString`; a view that
    /// already shows it reloads bypassing the cache (macOS `reloadFromOrigin`).
    @discardableResult public func reload(urlString: String) -> Bool {
        lastRequestedURLString = urlString
        isShowingStartPage = false
        if isLoading == false, currentURI == urlString {
            onLoadEvent?(.started)
            webkit_web_view_reload_bypass_cache(webView)
        } else {
            loadURI(urlString)
        }
        return true
    }

    override func perform(commandID: String) -> Bool {
        switch commandID {
        case "browser.location.focus": focusLocationField(); return true
        case "browser.reload": return reload()
        case "browser.annotate.toggle": return toggleAnnotationMode()
        case "find.show", "find.next", "find.previous", "find.hide":
            return performFind(commandID)
        default: return false
        }
    }

    override func focusContent() {
        if webState.restorableURL == nil && isShowingStartPage {
            focusLocationField()
        } else {
            gtk_widget_grab_focus(webViewWidget)
        }
    }

    override func applyTheme(isDark: Bool) {
        if isShowingStartPage {
            loadInternalPage(Self.startPageHTML(isDark: isDark))
        }
    }

    override func close() {
        #if TOASTTY_LINUX_APP_LOGIC
        annotation?.close()
        #endif
        super.close()
    }

    override func webProcessTerminated() {
        if loadIsInternal == false {
            onLoadEvent?(.failed(domain: "WebKitWebProcessTerminated", code: 0, message: "The web content process terminated"))
        }
        DesktopLauncher.toast("The page stopped responding", from: root, buttonLabel: nil, action: nil)
    }

    override func automationFacts() -> [String: String] {
        var facts: [String: String] = [
            "kind": "browser",
            "uri": currentURI ?? "",
            "title": webkit_web_view_get_title(webView).map { String(cString: $0) } ?? "",
            "loading": "\(isLoading)",
            "zoom": String(format: "%.2f", webkit_web_view_get_zoom_level(webView)),
        ]
        if let lastNavigationError { facts["error"] = lastNavigationError }
        #if TOASTTY_LINUX_APP_LOGIC
        if let annotation {
            let controller = annotation.controller
            facts["annotationMode"] = "\(controller.isAnnotationModeEnabled)"
            facts["annotationDrafts"] = "\(controller.draftCount)"
            facts["annotationComments"] = controller.annotationSummaries.map { "\($0.number):\($0.comment)" }.joined(separator: "|")
            facts["annotationPopover"] = switch controller.popover?.purpose {
            case .create: "create"
            case .edit: "edit"
            case .view: "view"
            case nil: "none"
            }
            facts["annotationPopoverShown"] = "\(annotation.isPopoverShown)"
            facts["annotationModeBar"] = "\(annotation.isModeBarShown)"
            facts["annotationNotice"] = annotation.lastNoticeMessage ?? ""
            facts["annotationSentTo"] = controller.lastSentSessionID ?? ""
            facts["annotationSentScreenshots"] = "\(controller.lastSentScreenshotPaths.count)"
        }
        #endif
        return facts
    }

    // MARK: Find in page (WebKitFindController)

    private var findBar: BrowserFindBar?

    private func performFind(_ commandID: String) -> Bool {
        let controller = webkit_web_view_get_find_controller(webView)!
        if findBar == nil {
            let bar = BrowserFindBar(controller: controller)
            findBar = bar
            // Above the web view, under the toolbar.
            gtk_widget_insert_after(bar.root, root, toolbar)
        }
        guard let findBar else { return false }
        switch commandID {
        case "find.show": findBar.show()
        case "find.next": findBar.next()
        case "find.previous": findBar.previous()
        default: findBar.hide()
        }
        return true
    }

    // MARK: Pages

    static func startPageHTML(isDark: Bool) -> String {
        let background = isDark ? "#242424" : "#fafafb"
        let foreground = isDark ? "#ffffffde" : "#000000cc"
        let muted = isDark ? "#ffffff80" : "#00000080"
        return """
        <!doctype html><html><head><meta charset="utf-8"><title></title>
        <style>
        html,body{height:100%;margin:0;background:\(background);color:\(foreground);font-family:system-ui,sans-serif}
        main{height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px}
        h1{font-size:15px;font-weight:600;margin:0}p{font-size:13px;color:\(muted);margin:0}
        kbd{font-family:inherit;border:1px solid \(muted);border-radius:4px;padding:0 4px}
        </style></head><body><main><h1>Browser</h1><p>Press <kbd>Ctrl</kbd>+<kbd>L</kbd> to enter an address.</p></main></body></html>
        """
    }

    static func invalidURLHTML(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>Browser</title></head><body style=\"font-family:system-ui;padding:2rem\"><h1>Invalid Browser URL</h1><p>Toastty could not load <code>\(escaped)</code>.</p></body></html>"
    }
}

/// Find bar for the browser (`WebKitFindController`).
@MainActor
final class BrowserFindBar {
    let root: WidgetPtr
    private let ref: GObjectRef
    private let entry: WidgetPtr
    private let status: WidgetPtr
    private let controller: OpaquePointer

    init(controller: OpaquePointer) {
        self.controller = controller
        root = Gtk.hbox(spacing: 4, classes: ["browser-find-bar", "toolbar"])
        ref = GObjectRef(sinking: root)
        Gtk.margins(root, top: 0, bottom: 4, start: 6, end: 6)
        entry = gtk_search_entry_new()!
        gtk_widget_set_hexpand(entry, 1)
        status = Gtk.label("", classes: ["dim-label", "caption"])
        let previous = Gtk.iconButton("go-up-symbolic", tooltip: "Previous (Shift+F3)")
        let next = Gtk.iconButton("go-down-symbolic", tooltip: "Next (F3)")
        let close = Gtk.iconButton("window-close-symbolic", tooltip: "Close")
        for child in [entry, status, previous, next, close] { Gtk.append(root, child) }
        Gtk.setVisible(root, false)

        Signal.connect(entry, "search-changed") { [weak self] in self?.search() }
        Signal.connect(entry, "activate") { [weak self] in self?.next() }
        Signal.connect(entry, "stop-search") { [weak self] in self?.hide() }
        Signal.connect(entry, "previous-match") { [weak self] in self?.previous() }
        Signal.connect(entry, "next-match") { [weak self] in self?.next() }
        Signal.connect(previous, "clicked") { [weak self] in self?.previous() }
        Signal.connect(next, "clicked") { [weak self] in self?.next() }
        Signal.connect(close, "clicked") { [weak self] in self?.hide() }
        Signal.connectUInt(controller, "found-text") { [weak self] count in
            guard let self else { return }
            Gtk.setLabel(self.status, count == 1 ? "1 match" : "\(count) matches")
        }
        Signal.connect(controller, "failed-to-find-text") { [weak self] in
            guard let self else { return }
            Gtk.setLabel(self.status, self.query.isEmpty ? "" : "No matches")
        }
    }

    private var query: String { String(cString: gtk_editable_get_text(cast(entry))) }

    func show() {
        Gtk.setVisible(root, true)
        gtk_widget_grab_focus(entry)
    }

    func hide() {
        webkit_find_controller_search_finish(cast(controller))
        Gtk.setLabel(status, "")
        Gtk.setVisible(root, false)
    }

    private func search() {
        guard query.isEmpty == false else {
            webkit_find_controller_search_finish(cast(controller))
            Gtk.setLabel(status, "")
            return
        }
        let options = WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE.rawValue | WEBKIT_FIND_OPTIONS_WRAP_AROUND.rawValue
        webkit_find_controller_search(cast(controller), query, options, 1000)
        webkit_find_controller_count_matches(cast(controller), query, options, 1000)
    }

    func next() {
        if gtk_widget_get_visible(root).bool == false { show(); return }
        webkit_find_controller_search_next(cast(controller))
    }

    func previous() {
        if gtk_widget_get_visible(root).bool == false { show(); return }
        webkit_find_controller_search_previous(cast(controller))
    }
}

/// Browser downloads: saved to the XDG Downloads directory with a unique
/// name, with a toast in the panel's window when done.
@MainActor
final class WebDownloads {
    static let shared = WebDownloads()
    private var watchedSessions: Set<OpaquePointer> = []
    private var active: [ObjectIdentifier: GObjectRef] = [:]

    func watch(session: OpaquePointer) {
        guard watchedSessions.insert(session).inserted else { return }
        Signal.connectPointer(session, "download-started") { [weak self] download in
            guard let self, let download else { return }
            self.track(OpaquePointer(download))
        }
    }

    static var downloadsDirectory: URL {
        if let path = g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD) {
            return URL(fileURLWithPath: String(cString: path))
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    /// `name`, or `name (2).ext`, … — the first that does not exist.
    nonisolated static func uniqueDestination(directory: URL, suggestedName: String) -> URL {
        var name = (suggestedName as NSString).lastPathComponent
        if name.isEmpty || name == "." || name == ".." { name = "download" }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            index += 1
        }
        return candidate
    }

    private func track(_ download: OpaquePointer) {
        let ref = GObjectRef(sinking: download)
        let key = ObjectIdentifier(ref)
        active[key] = ref
        let webViewWidget = webkit_download_get_web_view(cast(download)).map { widget($0) }
        Signal.connectPointerBool(download, "decide-destination") { suggested in
            let name = suggested.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? "download"
            let directory = Self.downloadsDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = Self.uniqueDestination(directory: directory, suggestedName: name)
            webkit_download_set_destination(cast(download), destination.path)
            return true
        }
        Signal.connect(download, "finished") { [weak self] in
            let destination = webkit_download_get_destination(cast(download)).map { String(cString: $0) }
            if let destination {
                let name = (destination as NSString).lastPathComponent
                DesktopLauncher.toast("Downloaded \(name)", from: webViewWidget)
            }
            MainLoop.idle { self?.active.removeValue(forKey: key) }
        }
        Signal.connectPointer(download, "failed") { [weak self] error in
            let message = error.map { String(cString: $0.assumingMemoryBound(to: GError.self).pointee.message) } ?? "unknown error"
            if message.lowercased().contains("cancel") == false {
                DesktopLauncher.toast("Download failed: \(message)", from: webViewWidget)
            }
            MainLoop.idle { self?.active.removeValue(forKey: key) }
        }
    }
}

/// Main-frame navigation results the browser panel reports to app-logic.
enum BrowserLoadEvent: Equatable {
    case started
    case finished
    case failed(domain: String, code: Int, message: String)
}
