import CGtk
import CoreState
import Foundation

extension LinuxAppController {
    /// Replaces the placeholder terminal host with Ghostty terminals once
    /// GTK has a display (application `startup`). `TOASTTY_LINUX_TERMINAL=placeholder`
    /// keeps the placeholder (layout-only UI tests); if libghostty cannot
    /// initialize, the placeholder stays and a warning is logged.
    ///
    /// `bridge` defaults to the reducer-only `StandaloneTerminalRuntimeBridge`;
    /// the app-logic build passes `AppLogicTerminalRuntimeBridge`.
    public func installTerminals(bridge makeBridge: (@MainActor (LinuxAppController) -> any TerminalRuntimeBridge)? = nil) {
        guard ProcessInfo.processInfo.environment["TOASTTY_LINUX_TERMINAL"] != "placeholder" else { return }
        Signal.connect(application, "startup", after: true) { [weak self] in
            guard let self else { return }
            let bridge = makeBridge?(self) ?? {
                let standalone = StandaloneTerminalRuntimeBridge(store: self.store)
                standalone.openExternally = { openURIExternally($0) }
                return standalone
            }()
            let host = GhosttyTerminalHost(bridge: bridge)
            guard host.isUsingFallback == false else {
                FileHandle.standardError.write(Data("toastty-linux: Ghostty is unavailable; using placeholder terminals\n".utf8))
                return
            }
            host.commandHandler = { [weak self] commandID, panelID in
                self?.performTerminalCommand(commandID, panelID: panelID) ?? false
            }
            host.closeRequestHandler = { [weak self] panelID in
                guard let self,
                      let windowID = self.store.state.workspaceSelection(containingPanelID: panelID)?.windowID,
                      let controller = self.windows[windowID] else {
                    bridge.closePanel(panelID: panelID)
                    return
                }
                controller.requestClosePanel(panelID)
            }
            self.hosts.terminal = host
            if self.automation != nil { TerminalAutomation.install() }
        }
    }

    public var ghosttyTerminalHost: GhosttyTerminalHost? { hosts.terminal as? GhosttyTerminalHost }

    /// A command that came from a terminal (Ghostty keybind action, mouse
    /// back/forward): like macOS `TerminalActionRouter`, focus the source
    /// panel first, then run it in that panel's window.
    func performTerminalCommand(_ commandID: String, panelID: UUID?) -> Bool {
        let state = store.state
        var windowID = state.selectedWindowID ?? state.windows.first?.id
        if let panelID, let selection = state.workspaceSelection(containingPanelID: panelID) {
            windowID = selection.windowID
            if state.workspacesByID[selection.workspaceID]?.focusedPanelID != panelID {
                store.send(.focusPanel(workspaceID: selection.workspaceID, panelID: panelID))
            }
        }
        guard let windowID, let controller = windows[windowID] else { return false }
        switch commandID {
        case "window.close", "app.quit":
            performAppCommand(commandID, windowID: windowID)
            return true
        default:
            return controller.perform(commandID)
        }
    }
}
