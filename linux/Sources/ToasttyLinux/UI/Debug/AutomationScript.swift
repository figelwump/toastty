import CGtk
import CGtkShim
import CoreState
import Foundation

/// In-process automation for headless (Broadway) smoke runs and visual
/// checks. Set `TOASTTY_LINUX_SMOKE_SCRIPT` to a file of commands, one per
/// line (`#` comments):
///
///     wait 300                      # milliseconds
///     action layout.split.horizontal  # activate win.<command-id> in the selected window
///     screenshot artifacts/manual/linux-ui/split.png
///     state out/state.json          # write a JSON summary of state + widgets
///     expect panes=2 zoomed=false   # compare summary values (`_` = space); failures exit 1
///     palette split                 # open the command palette with a query
///     dialog-respond rename Notes   # answer the visible alert dialog
///     dialog-click confirm          # press the response's button (the dialog's own `response` signal)
///     window-close                  # close the selected window (title-bar close button, Alt+F4)
///     alt-hints on|off              # show sidebar shortcut hints
///     resize 1280 800
///     perform agent.run.claude      # run a window command by id (shortcut/button path)
///     sidebar-width 320             # as if the sidebar handle were dragged (also right-panel-width)
///     quit
///
/// `TOASTTY_LINUX_SCREENSHOT_PATH` alone writes one screenshot after the
/// first render and quits.
@MainActor
public final class AutomationScript {
    public private(set) static var failures: [String] = []

    /// Script commands contributed by other workstreams (`web-*` from
    /// `WebPanelAutomation`). A handler may spin the main loop to wait.
    public static var extensionCommands: [String: @MainActor (_ app: LinuxAppController, _ argument: String, _ script: AutomationScript) -> Void] = [:]
    /// Extra summary keys for `state` / `expect`.
    public static var summaryContributors: [@MainActor (LinuxAppController) -> [String: String]] = []

    private var lines: [String]
    private var index = 0
    private weak var app: LinuxAppController?
    private let baseDirectory: URL

    public init(lines: [String], baseDirectory: URL) {
        self.lines = lines
        self.baseDirectory = baseDirectory
    }

    public static func fromEnvironment() -> AutomationScript? {
        let environment = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: environment["TOASTTY_LINUX_AUTOMATION_ROOT"] ?? FileManager.default.currentDirectoryPath)
        if let path = environment["TOASTTY_LINUX_SMOKE_SCRIPT"] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                FileHandle.standardError.write(Data("toastty-linux: cannot read smoke script \(path)\n".utf8))
                return nil
            }
            return AutomationScript(lines: text.components(separatedBy: .newlines), baseDirectory: base)
        }
        if let screenshot = environment["TOASTTY_LINUX_SCREENSHOT_PATH"] {
            return AutomationScript(lines: ["wait 600", "screenshot \(screenshot)", "quit"], baseDirectory: base)
        }
        return nil
    }

    func start(app: LinuxAppController) {
        self.app = app
        // Animations would wait on frame-clock ticks a viewerless Broadway
        // display never delivers.
        if let settings = gtk_settings_get_default() {
            GProperty.setBool(settings, "gtk-enable-animations", false)
        }
        // Under Broadway, give a viewer (the harness's headless browser) time
        // to attach so the frame clock runs before the first command.
        let deadline = Date().addingTimeInterval(
            ProcessInfo.processInfo.environment["GDK_BACKEND"] == "broadway" ? 15 : 0
        )
        MainLoop.timeout(milliseconds: 50) { [weak self] in
            guard let self, let app = self.app else { return false }
            let painted = app.orderedWindows.allSatisfy { controller in
                gtk_widget_get_frame_clock(controller.window).map { gdk_frame_clock_get_frame_counter($0) > 0 } ?? false
            }
            if painted == false, Date() < deadline { return true }
            if painted == false { self.log("no frames yet; continuing without a viewer") }
            self.step()
            return false
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[automation] \(message)\n".utf8))
    }

    /// Records a failure from an extension command.
    public func reportFailure(_ message: String) { fail(message) }

    /// Resolves a script path against the automation root.
    public func resolvePath(_ path: String) -> URL { resolve(path) }

    /// Lays out and paints pending changes (see `settle`).
    public func settleWindows(_ app: LinuxAppController) { settle(app: app) }

    public func logLine(_ message: String) { log(message) }

    private func fail(_ message: String) {
        Self.failures.append(message)
        log("FAIL \(message)")
    }

    private func step() {
        guard let app else { return }
        while index < lines.count {
            let raw = lines[index]
            index += 1
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard line.isEmpty == false else { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let command = parts[0]
            let argument = parts.count > 1 ? parts[1] : ""
            log(line)

            switch command {
            case "wait":
                let delay = UInt32(argument) ?? 200
                MainLoop.timeout(milliseconds: delay) { [weak self] in
                    self?.step()
                    return false
                }
                return
            case "action":
                guard let window = app.selectedWindowController() else { fail("action \(argument): no window"); continue }
                if window.activateAction(argument) == false { fail("action \(argument) not found") }
                MainLoop.spin(untilMilliseconds: 10)
                settle(app: app)
            case "perform":
                // Window command by id, as a shortcut or header button runs it.
                guard let window = app.selectedWindowController() else { fail("perform \(argument): no window"); continue }
                if window.perform(argument) == false { fail("perform \(argument) not handled") }
                settle(app: app)
            case "screenshot":
                screenshot(app: app, path: argument)
            case "state":
                writeSummary(app: app, path: argument)
            case "expect":
                settle(app: app)
                expect(app: app, argument)
            case "palette":
                guard let window = app.selectedWindowController() else { continue }
                window.handleUI(.commandPalette)
                if argument.isEmpty == false { window.palette?.setQuery(argument) }
            case "dialog-respond":
                let pieces = argument.split(separator: " ", maxSplits: 1).map(String.init)
                guard let dialog = Dialogs.current, let response = pieces.first else { fail("dialog-respond: no dialog"); continue }
                dialog.respond(response, text: pieces.count > 1 ? pieces[1] : nil)
            case "dialog-click":
                // Presses the response button itself, so the choice arrives
                // through the dialog's own `response` signal as a user's
                // click does (`dialog-respond` calls the callback directly).
                // The handle is not held across the click.
                guard let dialog = Dialogs.current?.dialog else { fail("dialog-click: no dialog"); continue }
                guard let button = Self.responseButton(argument, in: dialog) else {
                    fail("dialog-click: no button for response \(argument)")
                    continue
                }
                if gtk_widget_activate(button) == 0 { fail("dialog-click: \(argument) button did not activate") }
                // No settle: a confirmed quit destroys the windows meanwhile.
                MainLoop.spin(untilMilliseconds: 50)
            case "close-dialog":
                if let window = app.selectedWindowController(), let dialog = window.visibleDialog {
                    adw_dialog_force_close(cast(dialog))
                }
            case "alt-hints":
                app.selectedWindowController()?.sidebar.setShowsShortcutHints(argument == "on")
            case "resize":
                let size = argument.split(separator: " ").compactMap { Int32($0) }
                if size.count == 2, let window = app.selectedWindowController() {
                    gtk_window_set_default_size(cast(window.window), size[0], size[1])
                    forcedSize = (size[0], size[1])
                    settle(app: app)
                }
            case "sidebar-width", "right-panel-width":
                // Same path as dragging the resize handle.
                if let width = Double(argument), let window = app.selectedWindowController() {
                    if command == "sidebar-width" { window.resizeSidebar(to: width) } else { window.resizeRightPanel(to: width) }
                    settle(app: app)
                }
            case "window-close":
                // The title bar's close button / Alt+F4: `close-request` on the selected window.
                guard let window = app.selectedWindowController() else { fail("window-close: no window"); continue }
                gtk_window_close(cast(window.window))
                MainLoop.spin(untilMilliseconds: 10)
            case "color-scheme":
                if let scheme = LinuxColorSchemePreference(rawValue: argument) { app.preferences.colorScheme = scheme }
            case "quit":
                for controller in app.orderedWindows { controller.destroy() }
                g_application_quit(cast(app.application))
                return
            default:
                if let handler = Self.extensionCommands[command] {
                    handler(app, argument, self)
                } else {
                    fail("unknown automation command: \(line)")
                }
            }
        }
    }

    private func resolve(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDirectory.appendingPathComponent(path)
    }

    private func screenshot(app: LinuxAppController, path: String) {
        guard let window = app.selectedWindowController() else { fail("screenshot: no window"); return }
        let url = resolve(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        settle(app: app)
        var error: UnsafeMutablePointer<GError>?
        var background = LinuxTheme.isDark
            ? GdkRGBA(red: 0x22 / 255.0, green: 0x22 / 255.0, blue: 0x26 / 255.0, alpha: 1)
            : GdkRGBA(red: 0xfa / 255.0, green: 0xfa / 255.0, blue: 0xfb / 255.0, alpha: 1)
        if toastty_widget_write_png(window.window, url.path, &background, &error).bool == false {
            let message = error.map { String(cString: $0.pointee.message) } ?? "unknown error"
            if let error { g_error_free(error) }
            fail("screenshot \(path): \(message)")
        } else {
            log("wrote \(url.path)")
        }
    }

    /// Waits for the frame clock to lay out and paint pending changes. A
    /// Broadway display only produces frames while a viewer is attached
    /// (the smoke harness runs headless Chrome); without one, falls back to
    /// an explicit layout pass (`toastty_window_force_layout`), which cannot
    /// restyle widgets, so screenshots are only faithful with a viewer.
    private var forcedSize: (Int32, Int32)?

    private func settle(app: LinuxAppController) {
        MainLoop.spin(untilMilliseconds: 10)
        for controller in app.orderedWindows {
            guard let clock = gtk_widget_get_frame_clock(controller.window) else { continue }
            let start = gdk_frame_clock_get_frame_counter(clock)
            gtk_widget_queue_draw(controller.window)
            gtk_widget_queue_resize(controller.window)
            // Two frames: paned positions applied during the first layout
            // land in the second.
            MainLoop.spin(untilMilliseconds: 3000) {
                gdk_frame_clock_get_frame_counter(clock) >= start + 2
            }
            let advanced = gdk_frame_clock_get_frame_counter(clock) > start
            if advanced == false {
                if hasWarnedNoFrames == false {
                    hasWarnedNoFrames = true
                    log("frame clock is not advancing (no Broadway viewer?); forcing layout")
                }
                toastty_window_force_layout(cast(controller.window), forcedSize?.0 ?? 0, forcedSize?.1 ?? 0)
            }
        }
        MainLoop.spin(untilMilliseconds: 10)
    }

    private var hasWarnedNoFrames = false

    // MARK: Summary

    public static func summary(app: LinuxAppController) -> [String: String] {
        let state = app.store.state
        var result: [String: String] = ["windows": "\(state.windows.count)"]
        guard let controller = app.selectedWindowController(), let window = state.window(id: controller.windowID) else {
            return result
        }
        result["workspaces"] = "\(window.workspaceIDs.count)"
        result["sidebar"] = "\(window.sidebarVisible)"
        if let clock = gtk_widget_get_frame_clock(controller.window) {
            result["frameCounter"] = "\(gdk_frame_clock_get_frame_counter(clock))"
        }
        result["sidebarRows"] = "\(controller.sidebar.rowModels.count)"
        if let selection = state.workspaceSelection(in: window.id), let tab = selection.workspace.selectedTab {
            let workspace = selection.workspace
            result["workspace"] = workspace.title
            result["workspaceIndex"] = "\(window.workspaceIDs.firstIndex(of: selection.workspaceID) ?? -1)"
            result["tabs"] = "\(workspace.tabIDs.count)"
            result["tabIndex"] = "\(workspace.tabIDs.firstIndex(of: tab.id) ?? -1)"
            result["tabTitle"] = tab.displayTitle
            result["panes"] = "\(tab.layoutTree.allSlotInfos.count)"
            result["zoomed"] = "\(tab.focusedPanelModeActive)"
            result["rightPanel"] = "\(tab.rightAuxPanel.isVisible)"
            result["rightPanelTabs"] = "\(tab.rightAuxPanel.tabIDs.count)"
            let slots = tab.layoutTree.allSlotInfos.map(\.panelID)
            result["focusedPane"] = "\(tab.resolvedFocusedPanelID.flatMap { slots.firstIndex(of: $0) } ?? -1)"
            if let renderer = controller.content.renderer(workspaceID: selection.workspaceID, tabID: tab.id) {
                result["gtkPaneds"] = "\(countWidgets(of: gtk_paned_get_type(), in: renderer.root))"
                result["gtkPanelFrames"] = "\(countFrames(in: renderer.root))"
                result["rebuilds"] = "\(renderer.rebuildCount)"
            }
            if let focused = tab.resolvedFocusedPanelID {
                result["focusedFrameHighlighted"] = "\(controller.content.frame(for: focused)?.isFocused ?? false)"
            }
        }
        if let window = app.store.state.window(id: controller.windowID) {
            result["windowFrame"] = "\(Int(window.frame.width))x\(Int(window.frame.height))"
        }
        result["agentButtons"] = controller.agentButtonTitles.joined(separator: ",")
        result["agentShortcuts"] = TerminalProfileShortcuts.shared.agentCommands.compactMap(\.accelerator).joined(separator: ",")
        result["sidebarWidth"] = "\(gtk_widget_get_width(controller.sidebar.root))"
        result["rightPanelWidth"] = "\(gtk_widget_get_width(controller.rightPanel.root))"
        result["dialog"] = controller.visibleDialog.map { typeName($0) } ?? "none"
        // The response Enter picks in the visible alert, and the focused widget.
        result["dialogDefault"] = controller.visibleDialog
            .flatMap { isInstance($0, of: adw_alert_dialog_get_type()) ? adw_alert_dialog_get_default_response(cast($0)) : nil }
            .map { String(cString: $0) } ?? "none"
        if let focus = gtk_root_get_focus(cast(controller.window)) {
            let label = isInstance(focus, of: gtk_button_get_type()) ? gtk_button_get_label(cast(focus)).map { String(cString: $0) } : nil
            result["focusWidget"] = typeName(focus) + (label.map { ":\($0)" } ?? "")
        }
        // The window's icon (its own, else the default) and whether the icon
        // theme resolves it to Toastty's icon files.
        let windowIcon = gtk_window_get_icon_name(cast(controller.window)) ?? gtk_window_get_default_icon_name()
        result["windowIcon"] = windowIcon.map { String(cString: $0) } ?? "none"
        result["appIcon"] = AppIcon.resolvedFile().map { $0.hasPrefix("\(AppIcon.name).") ? "toastty" : $0 } ?? "missing"
        for contributor in summaryContributors {
            result.merge(contributor(app)) { _, new in new }
        }
        if let palette = controller.palette, controller.visibleDialog != nil {
            result["paletteResults"] = "\(palette.resultIDs.count)"
            result["paletteTop"] = palette.resultIDs.first ?? ""
        }
        return result
    }

    /// The button libadwaita built for an alert dialog's `response`, by label.
    private static func responseButton(_ response: String, in dialog: WidgetPtr) -> WidgetPtr? {
        guard adw_alert_dialog_has_response(cast(dialog), response) != 0,
              let label = adw_alert_dialog_get_response_label(cast(dialog), response).map({ String(cString: $0) }) else {
            return nil
        }
        func search(_ root: WidgetPtr) -> WidgetPtr? {
            if isInstance(root, of: gtk_button_get_type()),
               let current = gtk_button_get_label(cast(root)), String(cString: current) == label {
                return root
            }
            return Gtk.children(root).lazy.compactMap(search).first
        }
        return search(dialog)
    }

    private static func countWidgets(of type: GType, in root: WidgetPtr) -> Int {
        var count = isInstance(root, of: type) ? 1 : 0
        for child in Gtk.children(root) { count += countWidgets(of: type, in: child) }
        return count
    }

    private static func countFrames(in root: WidgetPtr) -> Int {
        var count = Gtk.hasClass(root, "panel-frame") ? 1 : 0
        for child in Gtk.children(root) { count += countFrames(in: child) }
        return count
    }

    private func writeSummary(app: LinuxAppController, path: String) {
        let summary = Self.summary(app: app)
        let url = resolve(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = (try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        do {
            try data.write(to: url)
        } catch {
            fail("state \(path): \(error)")
        }
    }

    private func expect(app: LinuxAppController, _ argument: String) {
        let summary = Self.summary(app: app)
        for pair in argument.split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { fail("bad expect term \(pair)"); continue }
            let actual = summary[kv[0]] ?? "<missing>"
            // `_` stands for a space in expected values.
            let expected = kv[1].replacingOccurrences(of: "_", with: " ")
            if actual != expected {
                fail("expected \(kv[0])=\(expected) but was \(actual)")
            }
        }
    }
}
