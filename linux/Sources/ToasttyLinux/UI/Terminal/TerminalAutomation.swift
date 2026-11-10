import CGtk
import CoreState
import Foundation

/// Smoke-script commands and summary keys for Ghostty terminals
/// (`TOASTTY_LINUX_SMOKE_SCRIPT`). All commands target the focused terminal
/// of the selected window.
///
///     terminal-type echo hi           # typed input (IME commit path)
///     terminal-send ls\n              # paste-style input; \n \t \e escapes
///     terminal-key Return             # key press+release (GTK accelerator syntax: <Control>c)
///     terminal-wait-text 5000 hi      # wait until the screen (with scrollback) contains text
///     terminal-expect-text hi         # fail unless the screen contains text
///     terminal-wait-prompt 5000       # wait for shell integration's idle prompt
///     terminal-wait-state 5000 focusedTerminalTitle=foo searchVisible=true
///     terminal-drop /tmp/a\ b.txt     # simulate a file drop (path list separated by |)
///     terminal-search line-4          # type into the open find bar
///     terminal-command terminal-profile.split-right.demo  # run any window command ID
///     terminal-context-menu           # open the right-click menu, check it is shown, close it
///     terminal-dump out/screen.txt    # write the screen text
@MainActor
enum TerminalAutomation {
    static func install() {
        let commands: [String: @MainActor (LinuxAppController, String, AutomationScript) -> Void] = [
            "terminal-type": { app, argument, script in
                guard let surface = focusedSurface(app, script) else { return }
                surface.typeText(unescape(argument))
                MainLoop.spin(untilMilliseconds: 30)
            },
            "terminal-send": { app, argument, script in
                guard let surface = focusedSurface(app, script) else { return }
                surface.sendText(unescape(argument))
                MainLoop.spin(untilMilliseconds: 30)
            },
            "terminal-key": { app, argument, script in
                guard let surface = focusedSurface(app, script) else { return }
                var keyval: guint = 0
                var mods = GdkModifierType(rawValue: 0)
                gtk_accelerator_parse(argument, &keyval, &mods)
                if keyval == 0 { keyval = gdk_keyval_from_name(argument) }
                guard keyval != 0 else { script.reportFailure("terminal-key: unknown key \(argument)"); return }
                surface.sendKey(keyval: keyval, state: mods)
                MainLoop.spin(untilMilliseconds: 30)
            },
            "terminal-wait-text": { app, argument, script in
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, let timeout = Int(parts[0]) else { script.reportFailure("terminal-wait-text: usage <ms> <text>"); return }
                guard let surface = focusedSurface(app, script) else { return }
                let needle = unescape(parts[1])
                let found = MainLoop.spin(untilMilliseconds: timeout) {
                    surface.readText(includeScrollback: true)?.contains(needle) ?? false
                }
                if found == false {
                    script.reportFailure("terminal text never contained \"\(needle)\"; screen:\n\(tail(surface))")
                }
            },
            "terminal-expect-text": { app, argument, script in
                guard let surface = focusedSurface(app, script) else { return }
                let needle = unescape(argument)
                if surface.readText(includeScrollback: true)?.contains(needle) != true {
                    script.reportFailure("terminal text does not contain \"\(needle)\"; screen:\n\(tail(surface))")
                }
            },
            "terminal-wait-prompt": { app, argument, script in
                guard let surface = focusedSurface(app, script) else { return }
                let ok = MainLoop.spin(untilMilliseconds: Int(argument) ?? 5000) { surface.promptState == .idleAtPrompt }
                if ok == false { script.reportFailure("terminal never reached an idle prompt (state \(surface.promptState.rawValue))") }
            },
            "terminal-wait-state": { app, argument, script in
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, let timeout = Int(parts[0]) else { script.reportFailure("terminal-wait-state: usage <ms> k=v ..."); return }
                let terms = parts[1].split(separator: " ").compactMap { pair -> (String, String)? in
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    return kv.count == 2 ? (kv[0], kv[1].replacingOccurrences(of: "_", with: " ")) : nil
                }
                let ok = MainLoop.spin(untilMilliseconds: timeout) {
                    let summary = AutomationScript.summary(app: app)
                    return terms.allSatisfy { summary[$0.0] == $0.1 }
                }
                if ok == false {
                    let summary = AutomationScript.summary(app: app)
                    let actual = terms.map { "\($0.0)=\(summary[$0.0] ?? "<missing>")" }.joined(separator: " ")
                    script.reportFailure("terminal-wait-state timed out: wanted \(parts[1]) got \(actual)")
                }
            },
            "terminal-drop": { app, argument, script in
                guard let host = app.ghosttyTerminalHost, let panelID = focusedPanelID(app) else {
                    script.reportFailure("terminal-drop: no focused terminal"); return
                }
                let paths = argument.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
                if host.insertDroppedPaths(paths, panelID: panelID) == false { script.reportFailure("terminal-drop rejected") }
                MainLoop.spin(untilMilliseconds: 30)
            },
            "terminal-search": { app, argument, script in
                guard let host = app.ghosttyTerminalHost, let panelID = focusedPanelID(app),
                      host.setSearchText(unescape(argument), panelID: panelID) else {
                    script.reportFailure("terminal-search: search bar is not open"); return
                }
                MainLoop.spin(untilMilliseconds: 50)
            },
            "terminal-command": { app, argument, script in
                guard let window = app.selectedWindowController() else { script.reportFailure("terminal-command: no window"); return }
                if window.perform(argument) == false { script.reportFailure("terminal-command \(argument) not handled") }
                MainLoop.spin(untilMilliseconds: 30)
                script.settleWindows(app)
            },
            "terminal-context-menu": { app, _, script in
                guard let host = app.ghosttyTerminalHost, let panelID = focusedPanelID(app),
                      host.showContextMenuForAutomation(panelID: panelID) else {
                    script.reportFailure("terminal-context-menu: no focused terminal"); return
                }
                MainLoop.spin(untilMilliseconds: 100)
                if host.contextMenuVisible(panelID: panelID) == false { script.reportFailure("context menu did not open") }
                host.hideContextMenu(panelID: panelID)
            },
            "terminal-dump": { app, argument, script in
                guard let surface = focusedSurface(app, script) else { return }
                let url = script.resolvePath(argument)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? (surface.readText(includeScrollback: true) ?? "").write(to: url, atomically: true, encoding: .utf8)
            },
        ]
        for (name, handler) in commands { AutomationScript.extensionCommands[name] = handler }
        AutomationScript.summaryContributors.append { app in summary(app) }
    }

    static func focusedPanelID(_ app: LinuxAppController) -> UUID? {
        guard let window = app.selectedWindowController(),
              let tab = app.store.state.workspaceSelection(in: window.windowID)?.workspace.selectedTab else { return nil }
        return tab.resolvedFocusedPanelID
    }

    private static func focusedSurface(_ app: LinuxAppController, _ script: AutomationScript) -> GhosttyTerminalSurface? {
        guard let panelID = focusedPanelID(app), let surface = app.ghosttyTerminalHost?.surface(for: panelID) else {
            script.reportFailure("no focused Ghostty terminal")
            return nil
        }
        return surface
    }

    private static func tail(_ surface: GhosttyTerminalSurface) -> String {
        let text = surface.readText(includeScrollback: false) ?? "<unreadable>"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(12).joined(separator: "\n")
    }

    static func unescape(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "e": result.append("\u{1B}")
            case "s": result.append(" ")
            default: result.append(next)
            }
        }
        return result
    }

    static func summary(_ app: LinuxAppController) -> [String: String] {
        guard let host = app.ghosttyTerminalHost else { return ["terminalBackend": "placeholder"] }
        var result: [String: String] = [
            "terminalBackend": "ghostty",
            "terminals": "\(host.livePanelIDs.count)",
        ]
        guard let window = app.selectedWindowController() else { return result }
        let state = app.store.state
        result["terminalFontPoints"] = String(format: "%.1f", state.effectiveTerminalFontPoints(for: window.windowID))
        if let tab = state.workspaceSelection(in: window.windowID)?.workspace.selectedTab {
            result["unreadPanels"] = "\(tab.unreadPanelIDs.count)"
        }
        guard let panelID = focusedPanelID(app), let surface = host.surface(for: panelID) else { return result }
        if case .terminal(let terminal)? = state.workspaceSelection(in: window.windowID)?.workspace.selectedTab?.panels[panelID] {
            result["focusedTerminalTitle"] = terminal.title
            result["focusedTerminalCwd"] = terminal.cwd
        }
        if let presentation = window.content.frame(for: panelID)?.currentPresentation {
            result["focusedHeaderTitle"] = presentation.title
            result["focusedHeaderSubtitle"] = presentation.subtitle ?? ""
        }
        result["terminalRenderer"] = surface.rendererName
        result["focusedPrompt"] = surface.promptState.rawValue
        result["focusedNeedsCloseConfirm"] = surface.needsCloseConfirmation.map { "\($0)" } ?? "unknown"
        result["terminalHasFocus"] = "\(surface.hasFocus)"
        result["contextMenu"] = "\(host.contextMenuVisible(panelID: panelID))"
        result["terminalAppliedFont"] = host.appliedFontPoints(panelID: panelID).map { String(format: "%.1f", $0) } ?? "none"
        if let grid = surface.gridSize { result["terminalGrid"] = "\(grid.columns)x\(grid.rows)" }
        let search = host.searchModel(for: panelID) ?? TerminalSearchModel()
        result["searchVisible"] = "\(search.isPresented)"
        result["searchNeedle"] = search.needle
        result["searchTotal"] = search.total.map(String.init) ?? "none"
        result["searchSelected"] = search.selected.map(String.init) ?? "none"
        result["unfocusedOverlays"] = "\(host.livePanelIDs.filter { host.isUnfocusedOverlayVisible(panelID: $0) }.count)"
        return result
    }
}
