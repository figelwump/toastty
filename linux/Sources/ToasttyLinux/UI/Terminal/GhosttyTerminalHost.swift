import CGtk
import CGtkShim
import CoreState
import Foundation
import GhosttyKit

/// Terminal panels backed by real Ghostty surfaces.
///
/// One `ToasttyGhosttySurface` per terminal panel, inside a `GtkOverlay`
/// container (search bar, unfocused-split dimming, link preview). The
/// container is created once and kept for the panel's lifetime, so split
/// re-layouts, tab and workspace switches only reparent it; the shell keeps
/// running. Ghostty actions route like macOS `TerminalActionRouter`:
/// title/pwd/bell/program status/command finished → `TerminalRuntimeBridge`,
/// split/goto/resize/zoom/tab/window keybind actions → Toastty commands,
/// search actions → the panel's search bar, `open_url` → right-panel browser
/// or the desktop's handler, close requests → Toastty's close path.
@MainActor
public final class GhosttyTerminalHost: TerminalPanelHosting, GhosttyRuntimeActionHandling {
    final class Entry {
        let panelID: UUID
        let container: GObjectRef
        let surface: GhosttyTerminalSurface
        let searchBar: TerminalSearchBar
        let unfocusedOverlay: WidgetPtr
        let linkLabel: WidgetPtr
        var search = TerminalSearchModel()
        var windowID: UUID
        var appliedFontPoints: Double?
        var contextMenu: GObjectRef?
        var consumedInsertPress = false

        init(panelID: UUID, container: WidgetPtr, surface: GhosttyTerminalSurface, searchBar: TerminalSearchBar,
             unfocusedOverlay: WidgetPtr, linkLabel: WidgetPtr, windowID: UUID) {
            self.panelID = panelID
            self.container = GObjectRef(sinking: container)
            self.surface = surface
            self.searchBar = searchBar
            self.unfocusedOverlay = unfocusedOverlay
            self.linkLabel = linkLabel
            self.windowID = windowID
        }
    }

    public let bridge: any TerminalRuntimeBridge
    let runtime: GhosttyRuntime?
    private let fallback = PlaceholderTerminalHost()
    private var entries: [UUID: Entry] = [:]
    private var panelBySurface: [UInt: UUID] = [:]
    private var panelByTerminal: [OpaquePointer: UUID] = [:]
    private var fontPointsByWindow: [UUID: Double] = [:]
    private var watchedWindows: Set<UnsafeMutableRawPointer> = []

    /// Runs a Toastty command (`LinuxCommandTable` ID, or `window.close`)
    /// in the window of `panelID` (nil: the selected window) after focusing
    /// that panel. Installed by `LinuxAppController`.
    public var commandHandler: ((_ commandID: String, _ panelID: UUID?) -> Bool)?
    /// Asks the user (if a process is running) and closes the panel.
    /// Installed by `LinuxAppController`; defaults to closing directly.
    public var closeRequestHandler: ((_ panelID: UUID) -> Void)?

    /// Ghostty is not available (library failed to initialize).
    public var isUsingFallback: Bool { runtime == nil }

    public init(bridge: any TerminalRuntimeBridge) {
        self.bridge = bridge
        self.runtime = GhosttyRuntime.shared
        runtime?.actionHandler = self
        if let runtime {
            bridge.setGhosttyConfiguredFontPoints(runtime.configuredFontPoints)
            runtime.onConfigurationChanged = { [weak self] in
                guard let self, let runtime = self.runtime else { return }
                self.bridge.setGhosttyConfiguredFontPoints(runtime.configuredFontPoints)
            }
        }
    }

    // MARK: Lookup (automation, tests, adapters)

    public func surface(for panelID: UUID) -> GhosttyTerminalSurface? { entries[panelID]?.surface }
    public func searchModel(for panelID: UUID) -> TerminalSearchModel? { entries[panelID]?.search }
    public var livePanelIDs: [UUID] { Array(entries.keys) }
    public var configDiagnostics: [String] { runtime?.diagnostics ?? [] }

    // MARK: PanelContentHosting

    public func contentWidget(for panelID: UUID, panel: PanelState, workspaceID: UUID, windowID: UUID) -> WidgetPtr {
        if let entry = entries[panelID] { return entry.container.widgetPointer }
        guard let runtime, let app = runtime.app, case .terminal(let terminal) = panel,
              let entry = makeEntry(panelID: panelID, terminal: terminal, windowID: windowID, app: app) else {
            return fallback.contentWidget(for: panelID, panel: panel, workspaceID: workspaceID, windowID: windowID)
        }
        entries[panelID] = entry
        if let ghosttySurface = entry.surface.surface {
            panelBySurface[UInt(bitPattern: ghosttySurface)] = panelID
        }
        panelByTerminal[entry.surface.terminal] = panelID
        bridge.surfaceDidAttach(entry.surface, panelID: panelID)
        // The widget spawns the shell as soon as the surface exists.
        bridge.surfaceDidLaunch(panelID: panelID)
        update(panelID: panelID, panel: panel)
        return entry.container.widgetPointer
    }

    public func update(panelID: UUID, panel: PanelState) {
        guard let entry = entries[panelID] else {
            fallback.update(panelID: panelID, panel: panel)
            return
        }
        let state = bridge.state
        if let selection = state.workspaceSelection(containingPanelID: panelID) {
            if selection.windowID != entry.windowID {
                entry.windowID = selection.windowID
                applyFont(entry, points: state.effectiveTerminalFontPoints(for: selection.windowID))
            }
            if let workspace = state.workspacesByID[selection.workspaceID],
               let tabID = workspace.tabID(containingPanelID: panelID),
               let tab = workspace.tab(id: tabID) {
                let siblings = tab.layoutTree.allSlotInfos.count > 1 && tab.focusedPanelModeActive == false
                let focused = tab.resolvedFocusedPanelID == panelID
                Gtk.setVisible(entry.unfocusedOverlay, siblings && focused == false)
            }
        }
    }

    public func focus(panelID: UUID) {
        guard let entry = entries[panelID] else {
            fallback.focus(panelID: panelID)
            return
        }
        if entry.search.isPresented, entry.searchBar.entryHasFocus { return }
        _ = entry.surface.grabFocus()
    }

    public func close(panelID: UUID) {
        guard let entry = entries.removeValue(forKey: panelID) else {
            fallback.close(panelID: panelID)
            return
        }
        panelBySurface = panelBySurface.filter { $0.value != panelID }
        panelByTerminal.removeValue(forKey: entry.surface.terminal)
        bridge.surfaceDidDetach(panelID: panelID)
        toastty_ghostty_surface_set_key_filter(entry.surface.terminal, nil, nil, nil)
        entry.surface.invalidate()
        if let menu = entry.contextMenu {
            gtk_widget_unparent(menu.widgetPointer)
            entry.contextMenu = nil
        }
        Gtk.detachFromParent(entry.container.widgetPointer)
    }

    public func perform(commandID: String, panelID: UUID) -> Bool {
        guard let entry = entries[panelID] else {
            return fallback.perform(commandID: commandID, panelID: panelID)
        }
        let surface = entry.surface
        switch commandID {
        case "find.show":
            if entry.search.isPresented {
                entry.searchBar.focusEntry()
                return true
            }
            return surface.performBindingAction("start_search")
        case "find.next":
            guard entry.search.isPresented else { return surface.performBindingAction("start_search") }
            return surface.performBindingAction("navigate_search:next")
        case "find.previous":
            guard entry.search.isPresented else { return surface.performBindingAction("start_search") }
            return surface.performBindingAction("navigate_search:previous")
        case "find.hide":
            return surface.performBindingAction("end_search")
        case "terminal.copy":
            return surface.performBindingAction("copy_to_clipboard")
        case "terminal.paste":
            bridge.noteLocalInput(.paste, panelID: panelID)
            return surface.performBindingAction("paste_from_clipboard")
        case "terminal.select-all":
            return surface.performBindingAction("select_all")
        case "terminal.clear":
            return surface.performBindingAction("clear_screen")
        default:
            return false
        }
    }

    /// `ghostty_surface_needs_confirm_quit` for the panel (nil: not a live terminal).
    public func needsCloseConfirmation(panelID: UUID) -> Bool? {
        entries[panelID]?.surface.needsCloseConfirmation
    }

    /// macOS `FocusedPanelCommandController`: closing a terminal whose
    /// process is still running asks first.
    public func confirmClose(panelID: UUID, parent: WidgetPtr, proceed: @escaping @MainActor () -> Void) -> Bool {
        guard entries[panelID]?.surface.needsCloseConfirmation == true else { return false }
        var body = "A process is still running in this terminal. Closing the panel will terminate it."
        if let pid = entries[panelID]?.surface.foregroundPID, let command = Self.processName(pid: pid) {
            body += "\n\nDetected command: \(command)"
        }
        Dialogs.confirm(parent: parent, heading: "Close this terminal?", body: body, confirmLabel: "_Close Terminal") {
            proceed()
        }
        return true
    }

    static func processName(pid: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"), data.isEmpty == false else { return nil }
        let parts = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : String(joined.prefix(120))
    }

    // MARK: TerminalPanelHosting

    public func setFontSize(points: Double, windowID: UUID) {
        fallback.setFontSize(points: points, windowID: windowID)
        guard fontPointsByWindow[windowID] != points else { return }
        fontPointsByWindow[windowID] = points
        for entry in entries.values where entry.windowID == windowID {
            applyFont(entry, points: points)
        }
    }

    private func applyFont(_ entry: Entry, points: Double) {
        guard entry.appliedFontPoints.map({ abs($0 - points) >= AppState.terminalFontComparisonEpsilon }) ?? true else { return }
        if entry.surface.performBindingAction("set_font_size:\(String(format: "%.2f", points))") {
            entry.appliedFontPoints = points
        }
    }

    // MARK: Surface creation

    private func makeEntry(panelID: UUID, terminal: TerminalPanelState, windowID: UUID, app: ghostty_app_t) -> Entry? {
        let spec = bridge.launchSpec(panelID: panelID, terminal: terminal, windowID: windowID)
        guard let widget = Self.makeSurfaceWidget(app: app, spec: spec) else {
            FileHandle.standardError.write(Data("toastty-linux: Ghostty surface creation failed for panel \(panelID)\n".utf8))
            return nil
        }
        let surface = GhosttyTerminalSurface(panelID: panelID, widget: widget)
        Gtk.expand(widget)
        gtk_widget_set_focusable(widget, 1)

        let overlay = gtk_overlay_new()!
        Gtk.addClasses(overlay, ["toastty-terminal", "panel-content"])
        Gtk.expand(overlay)
        gtk_overlay_set_child(cast(overlay), widget)

        let dim = Gtk.box(GTK_ORIENTATION_HORIZONTAL, classes: ["toastty-terminal-unfocused-overlay"])
        Gtk.expand(dim)
        gtk_widget_set_can_target(dim, 0)
        Gtk.setVisible(dim, false)
        gtk_overlay_add_overlay(cast(overlay), dim)

        let linkLabel = Gtk.label("", classes: ["terminal-link-hover"])
        gtk_widget_set_halign(linkLabel, GTK_ALIGN_START)
        gtk_widget_set_valign(linkLabel, GTK_ALIGN_END)
        gtk_widget_set_can_target(linkLabel, 0)
        gtk_label_set_ellipsize(cast(linkLabel), PANGO_ELLIPSIZE_MIDDLE)
        Gtk.setVisible(linkLabel, false)
        gtk_overlay_add_overlay(cast(overlay), linkLabel)

        let searchBar = TerminalSearchBar()
        gtk_overlay_add_overlay(cast(overlay), searchBar.root)

        let entry = Entry(
            panelID: panelID, container: overlay, surface: surface, searchBar: searchBar,
            unfocusedOverlay: dim, linkLabel: linkLabel, windowID: windowID
        )
        entry.appliedFontPoints = spec.fontPoints
        fontPointsByWindow[windowID] = fontPointsByWindow[windowID] ?? spec.fontPoints
        connectSignals(entry)
        installKeyFilter(entry)
        installSearchBar(entry)
        installFirstClickFocus(entry)
        installDropTargets(entry)
        installActions(entry)
        Signal.connect(overlay, "map") { [weak self] in self?.watchWindowActivity(of: overlay) }
        return entry
    }

    private static func makeSurfaceWidget(app: ghostty_app_t, spec: TerminalLaunchSpec) -> WidgetPtr? {
        var config = ghostty_surface_config_new()
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        config.wait_after_command = false
        if let points = spec.fontPoints { config.font_size = Float(points) }

        var allocations: [UnsafeMutablePointer<CChar>] = []
        func cString(_ value: String) -> UnsafeMutablePointer<CChar> {
            let pointer = strdup(value)!
            allocations.append(pointer)
            return pointer
        }
        defer { allocations.forEach { free($0) } }

        if let directory = spec.workingDirectory.map(Self.existingDirectory) {
            config.working_directory = UnsafePointer(cString(directory))
        }
        if let input = spec.initialInput, input.isEmpty == false {
            config.initial_input = UnsafePointer(cString(input))
        }
        let pairs = spec.environment.sorted { $0.key < $1.key }
        var envVars = pairs.map { ghostty_env_var_s(key: UnsafePointer(cString($0.key)), value: UnsafePointer(cString($0.value))) }
        return envVars.withUnsafeMutableBufferPointer { buffer in
            config.env_vars = buffer.count > 0 ? buffer.baseAddress : nil
            config.env_var_count = buffer.count
            return toastty_ghostty_surface_new(app, &config)
        }
    }

    /// A shell given a missing directory starts in `/`; use the nearest
    /// existing parent, or home (macOS `TerminalLaunchWorkingDirectory`).
    static func existingDirectory(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        func isDirectory(_ candidate: String) -> Bool {
            var flag: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &flag) && flag.boolValue
        }
        if isDirectory(expanded) { return expanded }
        var candidate = (expanded as NSString).standardizingPath
        while candidate.hasPrefix("/"), candidate != "/" {
            candidate = (candidate as NSString).deletingLastPathComponent
            if candidate != "/", isDirectory(candidate) { return candidate }
        }
        return NSHomeDirectory()
    }

    // MARK: Widget signals

    private func connectSignals(_ entry: Entry) {
        let widget = entry.surface.widget
        let panelID = entry.panelID
        TerminalSignal.connectString(widget, "title-changed") { [weak self] title in
            guard let title else { return }
            self?.bridge.handle(.title(title), panelID: panelID)
        }
        TerminalSignal.connectString(widget, "pwd-changed") { [weak self] pwd in
            guard let pwd else { return }
            self?.bridge.handle(.workingDirectory(pwd), panelID: panelID)
        }
        Signal.connect(widget, "bell") { [weak self] in
            self?.bridge.handle(.bell, panelID: panelID)
        }
        TerminalSignal.connectInt(widget, "close-requested") { [weak self] processAlive in
            self?.handleCloseRequest(panelID: panelID, processAlive: processAlive != 0)
        }
        TerminalSignal.connectUIntUInt64(widget, "child-exited") { [weak self] exitCode, runtimeMs in
            guard let self, let entry = self.entries[panelID] else { return }
            entry.surface.childExited = true
            self.bridge.handle(.childExited(exitCode: Int(exitCode), runtimeMilliseconds: runtimeMs), panelID: panelID)
        }
        TerminalSignal.connectIntUInt64(widget, "command-finished") { [weak self] exitCode, duration in
            self?.bridge.handle(.commandFinished(exitCode: exitCode >= 0 ? Int(exitCode) : nil, durationNanoseconds: duration), panelID: panelID)
        }
        Signal.connectPointer(widget, "program-status") { [weak self] pointer in
            guard let pointer,
                  let event = Self.programStatusEvent(pointer.assumingMemoryBound(to: ghostty_action_program_status_s.self).pointee) else { return }
            self?.bridge.handle(.programStatus(event), panelID: panelID)
        }
        TerminalSignal.connectInt(widget, "program-status-reset") { [weak self] reset in
            let event: TerminalProgramStatusEvent
            switch ghostty_program_status_reset_e(rawValue: UInt32(bitPattern: reset)) {
            case GHOSTTY_PROGRAM_STATUS_RESET_TERMINAL: event = .reset
            case GHOSTTY_PROGRAM_STATUS_RESET_PROMPT: event = .prompt
            case GHOSTTY_PROGRAM_STATUS_RESET_CHILD_EXIT: event = .exit
            default: return
            }
            self?.bridge.handle(.programStatus(event), panelID: panelID)
        }
        TerminalSignal.connectIntBool(widget, "mouse-navigation") { [weak self] direction in
            let command = direction == Int32(TOASTTY_GHOSTTY_NAVIGATION_BACK.rawValue) ? "navigation.back" : "navigation.forward"
            return self?.commandHandler?(command, panelID) ?? false
        }
        Signal.connectDoubles(widget, "context-menu") { [weak self] x, y in
            self?.showContextMenu(panelID: panelID, x: x, y: y)
        }
        TerminalSignal.connectString(widget, "link-hover") { [weak self] url in
            guard let entry = self?.entries[panelID] else { return }
            Gtk.setLabel(entry.linkLabel, url ?? "")
            Gtk.setVisible(entry.linkLabel, url?.isEmpty == false)
        }
    }

    private static func string(_ pointer: UnsafePointer<CChar>?, _ length: Int) -> String? {
        guard let pointer, length > 0 else { return nil }
        let buffer = UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: length)
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Copies a borrowed OSC 7501 report (macOS `makeGhosttyRuntimeAction`).
    static func programStatusEvent(_ report: ghostty_action_program_status_s) -> TerminalProgramStatusEvent? {
        let state: TerminalProgramStatusReport.State
        switch report.state {
        case GHOSTTY_PROGRAM_STATUS_STATE_IDLE: state = .idle
        case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: state = .working
        case GHOSTTY_PROGRAM_STATUS_STATE_DONE: state = .done
        case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED: state = .blocked
        case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: state = .error
        case GHOSTTY_PROGRAM_STATUS_STATE_CLEAR: state = .clear
        default: return nil
        }
        let kind: TerminalProgramStatusReport.Kind?
        switch report.kind {
        case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: kind = .permission
        case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: kind = .question
        case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: kind = .auth
        default: kind = nil
        }
        return .report(.init(
            state: state,
            id: string(report.id, Int(report.id_len)),
            app: string(report.app, Int(report.app_len)),
            title: string(report.title, Int(report.title_len)),
            message: string(report.msg, Int(report.msg_len)),
            kind: kind,
            progress: report.progress >= 0 ? Int(report.progress) : nil
        ))
    }

    private func handleCloseRequest(panelID: UUID, processAlive: Bool) {
        guard entries[panelID] != nil else { return }
        // `exit` in the shell: close like macOS without asking.
        if processAlive == false {
            bridge.closePanel(panelID: panelID)
            return
        }
        if let closeRequestHandler {
            closeRequestHandler(panelID)
        } else {
            bridge.closePanel(panelID: panelID)
        }
    }

    // MARK: Keyboard

    private final class KeyFilterBox {
        weak var host: GhosttyTerminalHost?
        let panelID: UUID
        init(host: GhosttyTerminalHost, panelID: UUID) {
            self.host = host
            self.panelID = panelID
        }
    }

    /// Called before the IME and Ghostty for every key. Toastty's own
    /// shortcuts never get here: the window's capture-phase controller
    /// (`KeyboardShortcutController`) consumes them first, so Ghostty's
    /// default Linux bindings for the same chords (Ctrl+Shift+T/N/W/O/E,
    /// Ctrl+±/0, …) never double-handle them.
    private func installKeyFilter(_ entry: Entry) {
        let box = Unmanaged.passRetained(KeyFilterBox(host: self, panelID: entry.panelID)).toOpaque()
        toastty_ghostty_surface_set_key_filter(
            entry.surface.terminal,
            { _, keyval, _, state, pressed, data in
                guard let data else { return 0 }
                let box = Unmanaged<KeyFilterBox>.fromOpaque(data).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    box.host?.filterKey(panelID: box.panelID, keyval: keyval, state: state, pressed: pressed != 0) ?? false
                } ? 1 : 0
            },
            box,
            { data in
                guard let data else { return }
                Unmanaged<KeyFilterBox>.fromOpaque(data).release()
            }
        )
    }

    static let modifierKeyvals: Set<Int32> = [
        GDK_KEY_Shift_L, GDK_KEY_Shift_R, GDK_KEY_Control_L, GDK_KEY_Control_R, GDK_KEY_Alt_L, GDK_KEY_Alt_R,
        GDK_KEY_Meta_L, GDK_KEY_Meta_R, GDK_KEY_Super_L, GDK_KEY_Super_R, GDK_KEY_ISO_Level3_Shift, GDK_KEY_Caps_Lock,
    ]

    func filterKey(panelID: UUID, keyval: UInt32, state: GdkModifierType, pressed: Bool) -> Bool {
        guard let entry = entries[panelID] else { return false }
        let key = Int32(keyval)
        let mods = state.rawValue & ShortcutMatcher.modifierMask

        // Shift+Insert pastes the clipboard (Toastty's Ubuntu table; Ghostty's
        // default would paste the primary selection).
        if key == GDK_KEY_Insert || key == GDK_KEY_KP_Insert {
            if pressed, mods == GDK_SHIFT_MASK.rawValue {
                bridge.noteLocalInput(.paste, panelID: panelID)
                entry.consumedInsertPress = entry.surface.performBindingAction("paste_from_clipboard")
                return entry.consumedInsertPress
            }
            if pressed == false, entry.consumedInsertPress {
                entry.consumedInsertPress = false
                return true
            }
        }

        guard pressed, Self.modifierKeyvals.contains(key) == false else { return false }
        let lower = gdk_keyval_to_lower(keyval)
        if mods == GDK_CONTROL_MASK.rawValue, Int32(lower) == GDK_KEY_c {
            bridge.noteLocalInput(.controlC, panelID: panelID)
        } else if mods == 0, key == GDK_KEY_Escape {
            bridge.noteLocalInput(.escape, panelID: panelID)
        } else if mods == (GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue), Int32(lower) == GDK_KEY_v {
            bridge.noteLocalInput(.paste, panelID: panelID)
        } else {
            bridge.noteLocalInput(.key, panelID: panelID)
        }
        return false
    }

    // MARK: Search

    private func installSearchBar(_ entry: Entry) {
        let panelID = entry.panelID
        let surface = entry.surface
        entry.searchBar.onNeedleChanged = { [weak self] needle in
            guard let entry = self?.entries[panelID] else { return }
            entry.search.needle = needle
            _ = surface.performBindingAction("search:\(needle)")
        }
        entry.searchBar.onNext = { _ = surface.performBindingAction("navigate_search:next") }
        entry.searchBar.onPrevious = { _ = surface.performBindingAction("navigate_search:previous") }
        entry.searchBar.onClose = { _ = surface.performBindingAction("end_search") }
    }

    private func handleSearchAction(_ action: ghostty_action_s, panelID: UUID) -> Bool {
        guard let entry = entries[panelID] else { return false }
        switch action.tag {
        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
            entry.search.isPresented = true
            if needle.isEmpty == false {
                entry.search.needle = needle
            }
            entry.searchBar.apply(entry.search)
            if needle.isEmpty == false {
                _ = entry.surface.performBindingAction("search:\(needle)")
            }
            if bridge.isPanelFocused(panelID) || entry.surface.hasFocus {
                entry.searchBar.focusEntry()
            }
        case GHOSTTY_ACTION_END_SEARCH:
            let hadFocus = entry.searchBar.entryHasFocus
            entry.search = TerminalSearchModel()
            entry.searchBar.apply(entry.search)
            if hadFocus { _ = entry.surface.grabFocus() }
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = Int(action.action.search_total.total)
            entry.search.total = total >= 0 ? total : nil
            entry.searchBar.apply(entry.search)
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = Int(action.action.search_selected.selected)
            entry.search.selected = selected >= 0 ? selected : nil
            entry.searchBar.apply(entry.search)
        default:
            return false
        }
        return true
    }

    // MARK: Focus

    /// macOS `TerminalHostView.mouseDown`: when focus moves here from another
    /// terminal in the active window, the first click only focuses the pane
    /// (so it does not also select text or click into a TUI).
    private func installFirstClickFocus(_ entry: Entry) {
        let gesture = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(gesture), 1)
        gtk_event_controller_set_propagation_phase(cast(gesture), GTK_PHASE_CAPTURE)
        let panelID = entry.panelID
        Signal.connectPress(gesture) { [weak self] _, _, _ in
            guard let self, let entry = self.entries[panelID] else { return }
            let widget = entry.surface.widget
            guard entry.surface.hasFocus == false,
                  let root = gtk_widget_get_root(widget),
                  gtk_window_is_active(cast(root)) != 0,
                  let focused = gtk_root_get_focus(root),
                  focused != widget,
                  isInstance(focused, of: toastty_ghostty_surface_get_type()) else { return }
            gtk_gesture_set_state(cast(gesture), GTK_EVENT_SEQUENCE_CLAIMED)
            _ = entry.surface.grabFocus()
            if let workspaceID = self.bridge.selection(containing: panelID)?.workspaceID {
                self.bridge.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
            }
        }
        gtk_widget_add_controller(entry.container.widgetPointer, cast(gesture))
    }

    /// Ghostty's app focus follows whether any Toastty window is active.
    private func watchWindowActivity(of widget: WidgetPtr) {
        guard let root = gtk_widget_get_root(widget) else { return }
        let window = UnsafeMutableRawPointer(root)
        if watchedWindows.insert(window).inserted {
            Signal.notify(window, "is-active") { [weak self] in self?.refreshAppFocus() }
            Signal.connect(window, "destroy") { [weak self] in
                self?.watchedWindows.remove(window)
                self?.refreshAppFocus()
            }
        }
        refreshAppFocus()
    }

    private func refreshAppFocus() {
        let active = watchedWindows.contains { gtk_window_is_active(cast($0)) != 0 }
        runtime?.setAppFocus(active)
    }

    // MARK: Context menu

    private func installActions(_ entry: Entry) {
        let group = g_simple_action_group_new()!
        let panelID = entry.panelID
        let actions: [(String, String)] = [
            ("copy", "terminal.copy"), ("paste", "terminal.paste"),
            ("select-all", "terminal.select-all"), ("find", "find.show"), ("clear", "terminal.clear"),
        ]
        for (name, command) in actions {
            let action = g_simple_action_new(name, nil)!
            Signal.connectPointer(action, "activate") { [weak self] _ in
                _ = self?.perform(commandID: command, panelID: panelID)
            }
            g_action_map_add_action(cast(group), cast(action))
            g_object_unref(UnsafeMutableRawPointer(action))
        }
        gtk_widget_insert_action_group(entry.container.widgetPointer, "term", cast(group))
        g_object_unref(UnsafeMutableRawPointer(group))
    }

    private func showContextMenu(panelID: UUID, x: Double, y: Double) {
        guard let entry = entries[panelID] else { return }
        if entry.contextMenu == nil {
            let menu = g_menu_new()!
            let clipboard = g_menu_new()!
            g_menu_append(clipboard, "Copy", "term.copy")
            g_menu_append(clipboard, "Paste", "term.paste")
            g_menu_append(clipboard, "Select All", "term.select-all")
            g_menu_append_section(menu, nil, cast(clipboard))
            let layout = g_menu_new()!
            g_menu_append(layout, "Split Right", "win.layout.split.horizontal")
            g_menu_append(layout, "Split Down", "win.layout.split.vertical")
            g_menu_append_section(menu, nil, cast(layout))
            let terminal = g_menu_new()!
            g_menu_append(terminal, "Find…", "term.find")
            g_menu_append(terminal, "Clear", "term.clear")
            g_menu_append(terminal, "Close Panel", "win.panel.close")
            g_menu_append_section(menu, nil, cast(terminal))
            for model in [clipboard, layout, terminal] { g_object_unref(UnsafeMutableRawPointer(model)) }
            let popover = gtk_popover_menu_new_from_model(cast(menu))!
            g_object_unref(UnsafeMutableRawPointer(menu))
            gtk_widget_set_parent(popover, entry.surface.widget)
            gtk_popover_set_has_arrow(cast(popover), 0)
            gtk_widget_set_halign(popover, GTK_ALIGN_START)
            entry.contextMenu = GObjectRef(sinking: popover)
        }
        guard let popover = entry.contextMenu?.widgetPointer else { return }
        // The pane is focused in state before menu actions read the focused panel.
        if let workspaceID = bridge.selection(containing: panelID)?.workspaceID {
            bridge.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
        }
        var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(cast(popover), &rect)
        gtk_popover_popup(cast(popover))
    }

    // MARK: Drag and drop

    /// Files insert shell-escaped paths (macOS `TerminalDropPayloadBuilder`);
    /// dropped images without a file (from a browser) are saved as PNGs
    /// under `$XDG_CACHE_HOME/toastty/dropped-images` and inserted as paths.
    private func installDropTargets(_ entry: Entry) {
        var types: [GType] = [gdk_file_list_get_type(), gdk_texture_get_type(), toastty_g_type_string()]
        let target = gtk_drop_target_new(GType(0), GDK_ACTION_COPY)!
        gtk_drop_target_set_gtypes(target, &types, gsize(types.count))
        let panelID = entry.panelID
        let container = entry.container.widgetPointer
        Signal.connectDropMotion(target, "enter") { _, _ in
            Gtk.setClass(container, "drop-target", true)
            return GDK_ACTION_COPY.rawValue
        }
        Signal.connect(target, "leave") {
            Gtk.setClass(container, "drop-target", false)
        }
        Signal.connectDrop(target) { [weak self] value, _, _ in
            Gtk.setClass(container, "drop-target", false)
            guard let self, let value else { return false }
            return self.handleDrop(value.assumingMemoryBound(to: GValue.self), panelID: panelID)
        }
        gtk_widget_add_controller(container, cast(target))
    }

    private func handleDrop(_ value: UnsafePointer<GValue>, panelID: UUID) -> Bool {
        guard let surface = entries[panelID]?.surface else { return false }
        let type = value.pointee.g_type
        var paths: [String] = []
        if type == gdk_file_list_get_type(), let list = g_value_get_boxed(value) {
            var node = gdk_file_list_get_files(OpaquePointer(list))
            let head = node
            while let current = node {
                if let file = current.pointee.data, let path = g_file_get_path(OpaquePointer(file)) {
                    paths.append(String(cString: path))
                    g_free(path)
                }
                node = current.pointee.next
            }
            g_slist_free(head)
        } else if type == gdk_texture_get_type(), let texture = g_value_get_object(value) {
            guard let path = Self.saveDroppedTexture(OpaquePointer(texture)) else { return false }
            paths.append(path)
        } else if let raw = toastty_value_get_string(value) {
            let text = String(cString: raw)
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            let fileURLs = lines.compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }.filter(\.isFileURL)
            if fileURLs.isEmpty == false, fileURLs.count == lines.count {
                paths = fileURLs.map(\.path)
            } else {
                bridge.noteLocalInput(.paste, panelID: panelID)
                surface.sendText(text)
                return true
            }
        }
        return insertDroppedPaths(paths, panelID: panelID)
    }

    /// Inserts shell-escaped paths like a file drop (macOS `handleFileDrop`).
    @discardableResult
    public func insertDroppedPaths(_ paths: [String], panelID: UUID) -> Bool {
        guard let surface = entries[panelID]?.surface,
              let payload = TerminalDropPayloadBuilder.shellEscapedPathPayload(forFilePaths: paths) else { return false }
        bridge.noteLocalInput(.paste, panelID: panelID)
        surface.sendText(payload)
        _ = surface.grabFocus()
        return true
    }

    /// Saves a texture like an image drop and inserts its path.
    @discardableResult
    public func insertDroppedTexture(_ texture: OpaquePointer, panelID: UUID) -> String? {
        guard let path = Self.saveDroppedTexture(texture), insertDroppedPaths([path], panelID: panelID) else { return nil }
        return path
    }

    func showContextMenuForAutomation(panelID: UUID) -> Bool {
        guard entries[panelID] != nil else { return false }
        showContextMenu(panelID: panelID, x: 80, y: 60)
        return true
    }

    func hideContextMenu(panelID: UUID) {
        if let menu = entries[panelID]?.contextMenu { gtk_popover_popdown(cast(menu.widgetPointer)) }
    }

    func contextMenuVisible(panelID: UUID) -> Bool {
        entries[panelID]?.contextMenu.map { gtk_widget_get_visible($0.widgetPointer) != 0 } ?? false
    }

    /// Types into the panel's open find bar (automation).
    func setSearchText(_ text: String, panelID: UUID) -> Bool {
        guard let entry = entries[panelID], entry.search.isPresented else { return false }
        entry.searchBar.setText(text)
        return true
    }

    func appliedFontPoints(panelID: UUID) -> Double? { entries[panelID]?.appliedFontPoints }
    func isUnfocusedOverlayVisible(panelID: UUID) -> Bool {
        entries[panelID].map { gtk_widget_get_visible($0.unfocusedOverlay) != 0 } ?? false
    }

    private static func saveDroppedTexture(_ texture: OpaquePointer) -> String? {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? "\(NSHomeDirectory())/.cache"
        let directory = "\(base)/toastty/dropped-images"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let path = "\(directory)/drop-\(stamp)-\(UUID().uuidString.prefix(8)).png"
        return gdk_texture_save_to_png(texture, path) != 0 ? path : nil
    }

    // MARK: Ghostty actions

    static let debugActions = ProcessInfo.processInfo.environment["TOASTTY_LINUX_TERMINAL_DEBUG"] == "1"

    func handleGhosttyAction(_ action: ghostty_action_s, surface: ghostty_surface_t?) -> Bool {
        let panelID = surface.flatMap { panelBySurface[UInt(bitPattern: $0)] }
        if Self.debugActions, action.tag != GHOSTTY_ACTION_RENDER {
            FileHandle.standardError.write(Data("toastty-linux: ghostty action \(action.tag.rawValue) panel=\(panelID?.uuidString ?? "app")\n".utf8))
        }
        func run(_ command: String) -> Bool { commandHandler?(command, panelID) ?? false }

        switch action.tag {
        case GHOSTTY_ACTION_START_SEARCH, GHOSTTY_ACTION_END_SEARCH, GHOSTTY_ACTION_SEARCH_TOTAL, GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let panelID else { return false }
            return handleSearchAction(action, panelID: panelID)

        case GHOSTTY_ACTION_NEW_SPLIT:
            switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_RIGHT: return run("layout.split.horizontal")
            case GHOSTTY_SPLIT_DIRECTION_DOWN: return run("layout.split.vertical")
            case GHOSTTY_SPLIT_DIRECTION_LEFT: return run("layout.split.left")
            case GHOSTTY_SPLIT_DIRECTION_UP: return run("layout.split.up")
            default: return false
            }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            switch action.action.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: return run("layout.split.select-previous")
            case GHOSTTY_GOTO_SPLIT_NEXT: return run("layout.split.select-next")
            case GHOSTTY_GOTO_SPLIT_LEFT: return run("layout.split.navigate-left")
            case GHOSTTY_GOTO_SPLIT_RIGHT: return run("layout.split.navigate-right")
            case GHOSTTY_GOTO_SPLIT_UP: return run("layout.split.navigate-up")
            case GHOSTTY_GOTO_SPLIT_DOWN: return run("layout.split.navigate-down")
            default: return false
            }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            switch action.action.resize_split.direction {
            case GHOSTTY_RESIZE_SPLIT_LEFT: return run("layout.split.resize-left")
            case GHOSTTY_RESIZE_SPLIT_RIGHT: return run("layout.split.resize-right")
            case GHOSTTY_RESIZE_SPLIT_UP: return run("layout.split.resize-up")
            case GHOSTTY_RESIZE_SPLIT_DOWN: return run("layout.split.resize-down")
            default: return false
            }
        case GHOSTTY_ACTION_EQUALIZE_SPLITS: return run("layout.split.equalize")
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM: return run("panel.focus-mode.toggle")
        case GHOSTTY_ACTION_NEW_TAB: return run("workspace.tab.create")
        case GHOSTTY_ACTION_CLOSE_TAB: return run("workspace.tab.close")
        case GHOSTTY_ACTION_NEW_WINDOW: return run("window.create")
        case GHOSTTY_ACTION_CLOSE_WINDOW: return run("window.close")
        case GHOSTTY_ACTION_QUIT, GHOSTTY_ACTION_CLOSE_ALL_WINDOWS: return run("app.quit")
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN: return run("window.fullscreen")
        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE: return run("command-palette.toggle")
        case GHOSTTY_ACTION_PROMPT_TITLE: return run("workspace.tab.rename")
        case GHOSTTY_ACTION_MOVE_TAB:
            return run(action.action.move_tab.amount > 0 ? "workspace.tab.move-right" : "workspace.tab.move-left")
        case GHOSTTY_ACTION_GOTO_TAB:
            let raw = action.action.goto_tab.rawValue
            switch action.action.goto_tab {
            case GHOSTTY_GOTO_TAB_PREVIOUS: return run("workspace.tab.select-previous")
            case GHOSTTY_GOTO_TAB_NEXT: return run("workspace.tab.select-next")
            case GHOSTTY_GOTO_TAB_LAST:
                let count = panelID.flatMap { bridge.selection(containing: $0) }
                    .flatMap { bridge.state.workspacesByID[$0.workspaceID]?.tabIDs.count } ?? 1
                return run("workspace.tab.select-\(max(count, 1))")
            default:
                return raw > 0 ? run("workspace.tab.select-\(raw)") : false
            }
        case GHOSTTY_ACTION_PRESENT_TERMINAL:
            guard let panelID, let workspaceID = bridge.selection(containing: panelID)?.workspaceID else { return false }
            return bridge.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            TerminalProfileShortcuts.shared.reload()
            return runtime?.reloadConfiguration() ?? false
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let panelID else { return false }
            let notification = action.action.desktop_notification
            bridge.handle(.desktopNotification(
                title: notification.title.map { String(cString: $0) } ?? "",
                body: notification.body.map { String(cString: $0) } ?? ""
            ), panelID: panelID)
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            guard let panelID,
                  let raw = Self.string(action.action.open_url.url, Int(action.action.open_url.len)),
                  let url = Self.linkURL(raw) else { return false }
            return bridge.openLink(url, panelID: panelID, alternate: Self.isShiftHeld())
        default:
            return false
        }
    }

    static func linkURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return nil
    }

    private static func isShiftHeld() -> Bool {
        guard let display = gdk_display_get_default(), let seat = gdk_display_get_default_seat(display),
              let keyboard = gdk_seat_get_keyboard(seat) else { return false }
        return gdk_device_get_modifier_state(keyboard).rawValue & GDK_SHIFT_MASK.rawValue != 0
    }
}

/// Opens a URI with the desktop's default handler.
@MainActor
func openURIExternally(_ url: URL) -> Bool {
    var error: UnsafeMutablePointer<GError>?
    let ok = g_app_info_launch_default_for_uri(url.absoluteString, nil, &error) != 0
    if let error {
        FileHandle.standardError.write(Data("toastty-linux: cannot open \(url.absoluteString): \(String(cString: error.pointee.message))\n".utf8))
        g_error_free(error)
    }
    return ok
}
