import CGtk
import CWebKitGtk
import CoreState
import Foundation

/// Local document panel: the generated `local-document-panel` bundle
/// (served as `toastty://local-document/`) rendering a Markdown / code /
/// config file, with the macOS native side ported: the edit/save state
/// machine (`LocalDocumentEditingSession`), bootstrap delivery over the
/// `toasttyLocalDocumentPanel` bridge, GFileMonitor reloads with conflict
/// detection, find (Ctrl+Shift+F), window text scale, Copy Full Path and
/// Open in Default App, and Ctrl+E / Ctrl+S / Escape.
@MainActor
public final class LocalDocumentPanelController: WebPanelController {
    public private(set) var session: LocalDocumentEditingSession?
    public private(set) var currentBootstrap: LocalDocumentPanelBootstrap?
    public private(set) var isBridgeReady = false
    public private(set) var isSearchControllerReady = false
    public private(set) var lastRenderedRevision: Int?
    private var pendingBootstrapScript: String?
    private var pendingRevealLine: Int?
    private var theme: LocalDocumentPanelTheme
    private var textScale: Double
    private var reloadGeneration = 0
    private var reloadDebounce: guint = 0
    private var fileMonitor: GObjectRef?
    private var monitoredPath: String?
    private var saveOperation: UUID?
    private let searchBar: LocalDocumentSearchBar

    nonisolated static let entryURI = "toastty://local-document/index.html"

    init(panelID: UUID, webState: WebPanelState, windowID: UUID, services: any WebPanelServices) {
        theme = LinuxTheme.isDark ? .dark : .light
        textScale = services.state.effectiveMarkdownTextScale(for: windowID)
        searchBar = LocalDocumentSearchBar()
        super.init(
            panelID: panelID, webState: webState, windowID: windowID, services: services,
            session: WebKitEnvironment.shared.ephemeralSession,
            settings: WebKitEnvironment.settings(developerExtras: WebKitEnvironment.developerExtrasEnabled),
            classes: ["local-document-panel"]
        )
        Gtk.append(root, searchBar.root)
        Gtk.append(root, webViewWidget)
        searchBar.onQuery = { [weak self] query in self?.runSearch(query.isEmpty ? .clear : .setQuery(query)) }
        searchBar.onNext = { [weak self] in _ = self?.findNext() }
        searchBar.onPrevious = { [weak self] in _ = self?.findPrevious() }
        searchBar.onClose = { [weak self] in _ = self?.endSearch() }

        addUserScript(Self.keyboardNavigationJavaScript, allFrames: false, atStart: false)
        registerMessageHandler(LocalDocumentBridgeEvent.handlerName) { [weak self] json in
            guard let self, let json, let event = LocalDocumentBridgeEvent(json: json) else { return }
            self.handle(event)
        }
        WebSignal.decidePolicy(webViewWidget) { [weak self] decision, type in
            self?.decidePolicy(decision, type: type) ?? false
        }
        installKeys()
        requestReload(debounced: false)
        webkit_web_view_load_uri(webView, Self.entryURI)
    }

    // MARK: Bridge

    private func handle(_ event: LocalDocumentBridgeEvent) {
        switch event {
        case .bridgeReady:
            isBridgeReady = true
            pendingBootstrapScript = nil
            pushBootstrap()
        case .renderReady(_, let revision, _):
            lastRenderedRevision = revision
        case .searchControllerReady:
            isSearchControllerReady = true
            if searchBar.isPresented, searchBar.query.isEmpty == false { runSearch(.setQuery(searchBar.query)) }
        case .searchControllerUnavailable:
            isSearchControllerReady = false
        case .enterEdit:
            _ = enterEdit()
        case .copyFullPath:
            if let path = session?.filePath {
                services.copyToClipboard(path)
                DesktopLauncher.toast("Copied \(path)", from: root)
            }
        case .openInDefaultApp:
            if let path = session?.filePath {
                _ = services.openExternally(URL(fileURLWithPath: path), parent: root)
            }
        case .draftDidChange(let content, let revision):
            guard var session, session.updateDraft(content, baseContentRevision: revision) else { return }
            self.session = session
            currentBootstrap = makeBootstrap()
        case .save(let revision):
            startSave(baseContentRevision: revision, allowConflictOverwrite: false)
        case .cancelEdit(let revision):
            guard var session, session.cancelEditing(baseContentRevision: revision) else { return }
            self.session = session
            refreshBootstrap()
        case .overwriteAfterConflict(let revision):
            startSave(baseContentRevision: revision, allowConflictOverwrite: true)
        case .consoleMessage(let level, let message):
            record("console.\(level): \(message)")
        case .javascriptError(let message, let source, let line, _, _):
            record("js error: \(message) (\(source ?? "?"):\(line ?? 0))")
        case .unhandledRejection(let reason, _):
            record("unhandled rejection: \(reason)")
        }
    }

    private func makeBootstrap() -> LocalDocumentPanelBootstrap? {
        session.map { LocalDocumentPanelBootstrap(session: $0, theme: theme, textScale: textScale) }
    }

    /// Rebuilds the bootstrap from the session and delivers it.
    private func refreshBootstrap(emitMetadata: Bool = false) {
        currentBootstrap = makeBootstrap()
        pendingBootstrapScript = currentBootstrap?.deliveryJavaScript()
        if emitMetadata, let name = currentBootstrap?.displayName {
            services.webPanelMetadataDidChange(panelID: panelID, title: name, url: nil)
        }
        pushBootstrap()
    }

    private func pushBootstrap() {
        guard isBridgeReady else { return }
        if pendingBootstrapScript == nil { pendingBootstrapScript = currentBootstrap?.deliveryJavaScript() }
        guard let script = pendingBootstrapScript else { return }
        evaluate(script) { [weak self] result in
            guard let self else { return }
            if case .success(let value) = result, WebJavaScript.bool(value) {
                if self.pendingBootstrapScript == script { self.pendingBootstrapScript = nil }
                self.pushPendingReveal()
                if self.searchBar.isPresented, self.searchBar.query.isEmpty == false {
                    self.runSearch(.setQuery(self.searchBar.query))
                }
            } else {
                self.record("bootstrap delivery deferred: \(result)")
            }
        }
    }

    private func pushPendingReveal() {
        guard let line = pendingRevealLine, isBridgeReady, pendingBootstrapScript == nil else { return }
        if session?.isEditing == true { pendingRevealLine = nil; return }
        evaluate(LocalDocumentBridgeScript.revealLine(line)) { [weak self] result in
            if case .success(let value) = result, WebJavaScript.bool(value) { self?.pendingRevealLine = nil }
        }
    }

    public func reveal(lineNumber: Int) {
        pendingRevealLine = lineNumber
        pushPendingReveal()
    }

    private func decidePolicy(_ decision: OpaquePointer, type: UInt32) -> Bool {
        guard type != WEBKIT_POLICY_DECISION_TYPE_RESPONSE.rawValue,
              let action = webkit_navigation_policy_decision_get_navigation_action(cast(decision)) else { return false }
        let uri = webkit_navigation_action_get_request(action).flatMap { webkit_uri_request_get_uri($0) }.map { String(cString: $0) } ?? ""
        let isLink = webkit_navigation_action_get_navigation_type(action) == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED
        switch Self.navigationPolicy(uri: uri, isLinkActivation: isLink) {
        case .allow:
            return false
        case .ignore:
            webkit_policy_decision_ignore(cast(decision))
            return true
        case .route:
            webkit_policy_decision_ignore(cast(decision))
            // A relative link resolves against the bundle URL; map it back
            // next to the document on disk.
            if let target = Self.linkTarget(for: uri, documentPath: session?.filePath) {
                _ = services.openSecondaryURL(target, fromPanelID: panelID)
            }
            return true
        }
    }

    enum NavigationPolicy: Equatable { case allow, ignore, route }

    /// The panel only ever shows its bundle; in-page anchors stay, clicked
    /// links leave through Toastty's router, anything else is dropped.
    nonisolated static func navigationPolicy(uri: String, isLinkActivation: Bool) -> NavigationPolicy {
        if uri.hasPrefix("about:") { return .allow }
        let isBundlePage = uri == entryURI || uri.hasPrefix(entryURI + "#") || uri == "toastty://local-document/"
        if isBundlePage { return isLinkActivation && uri.contains("#") == false ? .ignore : .allow }
        return isLinkActivation ? .route : .ignore
    }

    /// Where a link clicked inside a rendered document points.
    nonisolated static func linkTarget(for uri: String, documentPath: String?) -> URL? {
        guard let url = URL(string: uri) else { return nil }
        if url.scheme == "toastty", url.host == "local-document" {
            guard let documentPath else { return nil }
            let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            guard relative.isEmpty == false, relative != "index.html" else { return nil }
            let base = URL(fileURLWithPath: documentPath).deletingLastPathComponent()
            return base.appendingPathComponent(relative).standardizedFileURL
        }
        return url
    }

    // MARK: Loading and saving

    override func update(_ webState: WebPanelState, windowID: UUID) {
        let previousPath = self.webState.localDocument?.filePath
        let previousFormat = self.webState.localDocument?.format
        super.update(webState, windowID: windowID)
        if webState.localDocument?.filePath != previousPath || webState.localDocument?.format != previousFormat {
            requestReload(debounced: false)
        }
        let scale = services.state.effectiveMarkdownTextScale(for: windowID)
        if abs(scale - textScale) > 0.0001 {
            textScale = scale
            currentBootstrap = makeBootstrap()
            pendingBootstrapScript = nil
            if isBridgeReady {
                evaluate(LocalDocumentBridgeScript.textScale(scale)) { [weak self] result in
                    if case .success(let value) = result, WebJavaScript.bool(value) { return }
                    self?.pushBootstrap()
                }
            }
        }
    }

    override func applyTheme(isDark: Bool) {
        let next: LocalDocumentPanelTheme = isDark ? .dark : .light
        guard next != theme else { return }
        theme = next
        refreshBootstrap()
    }

    func requestReload(debounced: Bool) {
        MainLoop.cancel(reloadDebounce)
        reloadDebounce = 0
        if debounced {
            reloadDebounce = MainLoop.timeout(milliseconds: 150) { [weak self] in
                self?.reloadDebounce = 0
                self?.requestReload(debounced: false)
                return false
            }
            return
        }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let filePath = WebPanelState.normalizedFilePath(webState.localDocument?.filePath)
        let format = webState.localDocument?.format ?? .markdown
        let displayName = LocalDocumentSnapshot.displayName(for: webState)
        synchronizeFileMonitor(path: filePath)
        // GLib's main loop does not drain the libdispatch main queue, so the
        // hop back uses `MainLoop.dispatch` (g_idle_add) rather than MainActor.
        DispatchQueue.global(qos: .userInitiated).async {
            let document = LocalDocumentSnapshot.load(filePath: filePath, displayName: displayName, format: format)
            MainLoop.dispatch { [weak self] in
                guard let self, self.isClosed == false, generation == self.reloadGeneration else { return }
                self.applyLoadedDocument(document)
            }
        }
    }

    private func applyLoadedDocument(_ document: LocalDocumentSnapshot) {
        if var existing = session {
            guard existing.applyReload(document) else { return }
            session = existing
        } else {
            session = LocalDocumentEditingSession(document: document)
        }
        refreshBootstrap(emitMetadata: true)
    }

    private func synchronizeFileMonitor(path: String?) {
        guard path != monitoredPath else { return }
        monitoredPath = path
        if let fileMonitor { g_file_monitor_cancel(cast(fileMonitor.pointer)) }
        fileMonitor = nil
        guard let path else { return }
        let file = g_file_new_for_path(path)!
        defer { g_object_unref(UnsafeMutableRawPointer(file)) }
        var error: UnsafeMutablePointer<GError>?
        guard let monitor = g_file_monitor_file(file, GFileMonitorFlags(rawValue: 0), nil, &error) else {
            if let error { record("file monitor: \(String(cString: error.pointee.message))"); g_error_free(error) }
            return
        }
        fileMonitor = GObjectRef(adopting: monitor)
        WebSignal.fileMonitorChanged(monitor) { [weak self] event in
            // Ignore attribute-only changes; editors' atomic saves arrive as
            // DELETED + CREATED or CHANGES_DONE_HINT.
            guard event != G_FILE_MONITOR_EVENT_ATTRIBUTE_CHANGED.rawValue, event != G_FILE_MONITOR_EVENT_PRE_UNMOUNT.rawValue else { return }
            self?.requestReload(debounced: true)
        }
    }

    private func startSave(baseContentRevision: Int, allowConflictOverwrite: Bool) {
        guard var session else { return }
        if allowConflictOverwrite == false, session.finishNoOpSave(baseContentRevision: baseContentRevision) {
            self.session = session
            refreshBootstrap()
            return
        }
        guard let request = session.beginSave(baseContentRevision: baseContentRevision, allowConflictOverwrite: allowConflictOverwrite) else { return }
        let operation = UUID()
        saveOperation = operation
        self.session = session
        refreshBootstrap()
        let format = session.format
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<LocalDocumentSnapshot, any Error>
            do {
                try request.content.write(toFile: request.filePath, atomically: true, encoding: .utf8)
                let saved = LocalDocumentSnapshot.load(filePath: request.filePath, displayName: request.displayName, format: format)
                outcome = .success(saved)
            } catch {
                outcome = .failure(error)
            }
            nonisolated(unsafe) let result = outcome
            MainLoop.dispatch { [weak self] in
                self?.finishSave(operation: operation, request: request, outcome: result)
            }
        }
    }

    private func finishSave(operation: UUID, request: LocalDocumentSaveRequest, outcome: Result<LocalDocumentSnapshot, Error>) {
        guard saveOperation == operation, var session else { return }
        saveOperation = nil
        switch outcome {
        case .success(let document):
            guard session.settleSave(with: document, expectedContent: request.content, baseContentRevision: request.baseContentRevision) else { return }
        case .failure(let error):
            guard session.failSave(message: error.localizedDescription, baseContentRevision: request.baseContentRevision) else { return }
        }
        self.session = session
        refreshBootstrap()
    }

    // MARK: Commands

    public var canEnterEdit: Bool { session?.canEnterEdit ?? false }
    public var canSave: Bool { session?.canSave ?? false }
    public var canCancelEdit: Bool { session?.canCancelEdit ?? false }

    @discardableResult
    public func enterEdit() -> Bool {
        guard var session, session.beginEditing() else { return false }
        self.session = session
        pendingRevealLine = nil
        refreshBootstrap()
        return true
    }

    @discardableResult
    public func save() -> Bool {
        guard let session, session.canSave else { return false }
        startSave(baseContentRevision: session.contentRevision, allowConflictOverwrite: false)
        return true
    }

    @discardableResult
    public func cancelEdit() -> Bool {
        guard var session, session.canCancelEdit, session.cancelEditing(baseContentRevision: session.contentRevision) else { return false }
        self.session = session
        refreshBootstrap()
        return true
    }

    override func perform(commandID: String) -> Bool {
        switch commandID {
        case "local-document.edit": return enterEdit() || session?.isEditing == true
        case "local-document.save": _ = save(); return true
        case "find.show": return startSearch()
        case "find.next": return findNext()
        case "find.previous": return findPrevious()
        case "find.hide": return endSearch()
        default: return false
        }
    }

    private func installKeys() {
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        Signal.connectKeyPressed(keys) { [weak self] keyval, _, state in
            guard let self else { return false }
            let mods = state.rawValue & (GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue)
            let key = Int32(keyval)
            if mods == GDK_CONTROL_MASK.rawValue, key == GDK_KEY_e || key == GDK_KEY_E {
                return self.enterEdit() || self.session?.isEditing == true
            }
            if mods == GDK_CONTROL_MASK.rawValue, key == GDK_KEY_s || key == GDK_KEY_S {
                // Ctrl+S belongs to the document even when save is disabled.
                _ = self.save()
                return true
            }
            if mods == 0, key == GDK_KEY_Escape {
                if self.searchBar.hasFocus { _ = self.endSearch(); return true }
                if self.canCancelEdit { return self.cancelEdit() }
            }
            return false
        }
        gtk_widget_add_controller(root, keys)
    }

    override var closeConfirmationMessage: (heading: String, body: String)? {
        guard let session, session.needsCloseConfirmation else { return nil }
        if session.isSaving {
            return ("“\(session.displayName)” Is Still Saving", "Closing now may lose the save in progress.")
        }
        return ("Discard Changes to “\(session.displayName)”?", "Your unsaved edits will be lost.")
    }

    override func close() {
        MainLoop.cancel(reloadDebounce)
        reloadDebounce = 0
        if let fileMonitor { g_file_monitor_cancel(cast(fileMonitor.pointer)) }
        fileMonitor = nil
        super.close()
    }

    // MARK: Search

    public private(set) var lastSearchResult: LocalDocumentSearchResult?

    @discardableResult
    public func startSearch() -> Bool {
        searchBar.present()
        if searchBar.query.isEmpty == false { runSearch(.setQuery(searchBar.query)) }
        return true
    }

    @discardableResult
    public func findNext() -> Bool {
        guard searchBar.query.isEmpty == false else { return startSearch() }
        runSearch(.findNext(searchBar.query))
        return true
    }

    @discardableResult
    public func findPrevious() -> Bool {
        guard searchBar.query.isEmpty == false else { return startSearch() }
        runSearch(.findPrevious(searchBar.query))
        return true
    }

    @discardableResult
    public func endSearch() -> Bool {
        guard searchBar.isPresented else { return false }
        searchBar.dismiss()
        runSearch(.clear)
        gtk_widget_grab_focus(webViewWidget)
        return true
    }

    public func setSearchQuery(_ query: String?) {
        if let query {
            searchBar.present(query: query)
            runSearch(query.isEmpty ? .clear : .setQuery(query))
        } else {
            _ = endSearch()
        }
    }

    private func runSearch(_ command: LocalDocumentSearchCommand) {
        evaluate(LocalDocumentBridgeScript.search(command)) { [weak self] result in
            guard let self else { return }
            guard case .success(let json?) = result, let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(LocalDocumentSearchResult.self, from: data) else {
                if case .clear = command { self.lastSearchResult = nil }
                self.searchBar.show(result: nil)
                return
            }
            self.lastSearchResult = decoded
            self.searchBar.show(result: decoded)
        }
    }

    override func automationFacts() -> [String: String] {
        var facts: [String: String] = [
            "kind": "localDocument",
            "bridgeReady": "\(isBridgeReady)",
            "filePath": session?.filePath ?? "",
            "displayName": session?.displayName ?? "",
            "format": session?.format.rawValue ?? "",
            "isEditing": "\(session?.isEditing ?? false)",
            "isDirty": "\(session?.isDirty ?? false)",
            "contentRevision": "\(session?.contentRevision ?? 0)",
            "renderedRevision": "\(lastRenderedRevision ?? 0)",
            "textScale": String(format: "%.2f", textScale),
            "theme": theme.rawValue,
        ]
        if let lastSearchResult { facts["searchMatches"] = "\(lastSearchResult.matchCount)" }
        return facts
    }

    /// macOS `LocalDocumentPanelRuntime.keyboardNavigationJavaScript`: arrow
    /// keys scroll the code view when focus is not in an editable element.
    static let keyboardNavigationJavaScript = """
    (() => {
      const installFlag = "__toasttyLocalDocumentKeyboardNavigationInstalled";
      if (window[installFlag] === true) { return; }
      window[installFlag] = true;
      const scrollContainerSelector = ".local-document-code-scroll";
      const handledKeys = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]);
      const isInteractiveTarget = (element) => {
        if (!(element instanceof Element)) { return false; }
        if (element instanceof HTMLTextAreaElement || element instanceof HTMLInputElement ||
            element instanceof HTMLSelectElement || element instanceof HTMLButtonElement ||
            element instanceof HTMLAnchorElement) { return true; }
        return element.isContentEditable ||
          element.closest("textarea, input, select, button, a[href], [contenteditable='true'], [contenteditable='']");
      };
      const scrollStep = (container, axis) => {
        const lineHeight = Number.parseFloat(window.getComputedStyle(container).lineHeight);
        const baseStep = Number.isFinite(lineHeight) && lineHeight > 0 ? lineHeight : 20;
        return axis === "y" ? Math.max(baseStep * 3, 36) : Math.max(baseStep * 2, 32);
      };
      document.addEventListener("keydown", (event) => {
        if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey ||
            handledKeys.has(event.key) === false) { return; }
        const eventTarget = event.target instanceof Element ? event.target : document.activeElement;
        if (isInteractiveTarget(eventTarget)) { return; }
        const container = document.querySelector(scrollContainerSelector);
        if (!(container instanceof HTMLElement)) { return; }
        let deltaLeft = 0;
        let deltaTop = 0;
        switch (event.key) {
        case "ArrowUp": deltaTop = -scrollStep(container, "y"); break;
        case "ArrowDown": deltaTop = scrollStep(container, "y"); break;
        case "ArrowLeft": deltaLeft = -scrollStep(container, "x"); break;
        case "ArrowRight": deltaLeft = scrollStep(container, "x"); break;
        default: return;
        }
        const canScrollVertically = container.scrollHeight > container.clientHeight + 1;
        const canScrollHorizontally = container.scrollWidth > container.clientWidth + 1;
        if ((deltaTop !== 0 && canScrollVertically === false) || (deltaLeft !== 0 && canScrollHorizontally === false)) { return; }
        container.scrollBy({ left: deltaLeft, top: deltaTop, behavior: "auto" });
        event.preventDefault();
      }, { capture: true });
    })();
    """
}

/// Find bar above a local document (macOS `LocalDocumentPanelSearchBar`).
@MainActor
final class LocalDocumentSearchBar {
    let root: WidgetPtr
    private let ref: GObjectRef
    private let entry: WidgetPtr
    private let status: WidgetPtr
    private var suppressChange = false
    var onQuery: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        root = Gtk.hbox(spacing: 4, classes: ["local-document-search", "toolbar"])
        ref = GObjectRef(sinking: root)
        Gtk.margins(root, top: 4, bottom: 4, start: 6, end: 6)
        entry = gtk_search_entry_new()!
        gtk_widget_set_hexpand(entry, 1)
        gtk_search_entry_set_placeholder_text(cast(entry), "Find in document")
        Gtk.setName(entry, "local-document-search-entry")
        status = Gtk.label("", classes: ["dim-label", "caption"], ellipsize: false)
        let previous = Gtk.iconButton("go-up-symbolic", tooltip: "Previous (Shift+F3)")
        let next = Gtk.iconButton("go-down-symbolic", tooltip: "Next (F3)")
        let close = Gtk.iconButton("window-close-symbolic", tooltip: "Close (Escape)")
        for child in [entry, status, previous, next, close] { Gtk.append(root, child) }
        Gtk.setVisible(root, false)

        Signal.connect(entry, "search-changed") { [weak self] in
            guard let self, self.suppressChange == false else { return }
            self.onQuery?(self.query)
        }
        Signal.connect(entry, "activate") { [weak self] in self?.onNext?() }
        Signal.connect(entry, "next-match") { [weak self] in self?.onNext?() }
        Signal.connect(entry, "previous-match") { [weak self] in self?.onPrevious?() }
        Signal.connect(entry, "stop-search") { [weak self] in self?.onClose?() }
        Signal.connect(previous, "clicked") { [weak self] in self?.onPrevious?() }
        Signal.connect(next, "clicked") { [weak self] in self?.onNext?() }
        Signal.connect(close, "clicked") { [weak self] in self?.onClose?() }
    }

    var query: String { String(cString: gtk_editable_get_text(cast(entry))) }
    var isPresented: Bool { gtk_widget_get_visible(root).bool }
    var hasFocus: Bool {
        let text = gtk_widget_get_first_child(entry)
        return gtk_widget_has_focus(entry).bool || (text.map { gtk_widget_has_focus($0).bool } ?? false)
    }

    func present(query: String? = nil) {
        if let query {
            suppressChange = true
            gtk_editable_set_text(cast(entry), query)
            suppressChange = false
        }
        Gtk.setVisible(root, true)
        gtk_widget_grab_focus(entry)
    }

    func dismiss() {
        Gtk.setVisible(root, false)
        Gtk.setLabel(status, "")
    }

    func show(result: LocalDocumentSearchResult?) {
        guard let result, result.query.isEmpty == false else {
            Gtk.setLabel(status, "")
            return
        }
        if result.matchCount == 0 {
            Gtk.setLabel(status, "No matches")
        } else if let active = result.activeMatchIndex {
            Gtk.setLabel(status, "\(active + 1) of \(result.matchCount)")
        } else {
            Gtk.setLabel(status, result.matchCount == 1 ? "1 match" : "\(result.matchCount) matches")
        }
    }
}
