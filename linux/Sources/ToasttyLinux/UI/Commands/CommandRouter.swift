import CoreState
import Foundation

/// UI work a command needs before (or instead of) touching state.
public enum LinuxUICommand: Equatable, Sendable {
    case renameWorkspace(workspaceID: UUID)
    case renameTab(workspaceID: UUID, tabID: UUID)
    case confirmCloseWorkspace(workspaceID: UUID)
    case confirmCloseTab(workspaceID: UUID, tabID: UUID)
    case commandPalette
    case preferences
    case shortcuts
    case about
    case toggleFullscreen
    case quit
    /// Routed to the focused panel's host (find, text size for web panels,
    /// browser/document commands, clipboard).
    case panel(commandID: String, panelID: UUID)
}

public enum LinuxCommandRoute: Equatable, Sendable {
    /// Reducer actions dispatched in order.
    case actions([AppAction])
    case ui(LinuxUICommand)
    /// Needs the app-logic layer (`LinuxAppCommandHandling`).
    case app(String)
    /// Valid command with nothing to do in the current state.
    case none
}

/// Maps a Toastty command ID to what it does in a window, from state alone.
/// Pure, so command semantics are unit-tested without GTK.
public enum CommandRouter {
    public static let resizeAmount = 5

    public static func route(_ commandID: String, windowID: UUID, state: AppState) -> LinuxCommandRoute {
        let selection = state.workspaceSelection(in: windowID)
        let workspace = selection?.workspace
        let workspaceID = selection?.workspaceID
        let tab = workspace?.selectedTab
        let focusedPanelID = tab?.resolvedFocusedPanelID
        // Panel-scoped commands (find, browser, document, text size) go to
        // the right panel's focused tab while it has focus.
        let rightPanel = workspace?.rightAuxPanel
        let rightPanelFocusedID = rightPanel?.isVisible == true ? rightPanel?.focusedPanelID : nil
        let panelTargetID = rightPanelFocusedID ?? focusedPanelID
        let panelTarget: PanelState? = panelTargetID.flatMap { id in
            rightPanelFocusedID == id ? rightPanel?.panelState(for: id) : tab?.panels[id]
        }

        func withWorkspace(_ make: (UUID) -> AppAction) -> LinuxCommandRoute {
            guard let workspaceID else { return .none }
            return .actions([make(workspaceID)])
        }

        if let number = suffixNumber(commandID, prefix: "workspace.tab.select-") {
            guard let workspace, let workspaceID, number <= workspace.tabIDs.count else { return .none }
            return .actions([.selectWorkspaceTab(workspaceID: workspaceID, tabID: workspace.tabIDs[number - 1])])
        }
        if let number = suffixNumber(commandID, prefix: "workspace.select-") {
            guard let window = state.window(id: windowID), number <= window.workspaceIDs.count else { return .none }
            return .actions([.selectWorkspace(windowID: windowID, workspaceID: window.workspaceIDs[number - 1])])
        }
        if let number = suffixNumber(commandID, prefix: "layout.pane.focus-") {
            guard let tab, let workspaceID else { return .none }
            let slots = tab.layoutTree.allSlotInfos
            guard number <= slots.count else { return .none }
            return .actions([.focusPanel(workspaceID: workspaceID, panelID: slots[number - 1].panelID)])
        }

        switch commandID {
        // Application
        case "command-palette.toggle": return .ui(.commandPalette)
        case "app.preferences": return .ui(.preferences)
        case "app.shortcuts": return .ui(.shortcuts)
        case "app.about": return .ui(.about)
        case "app.quit": return .ui(.quit)
        case "window.fullscreen": return .ui(.toggleFullscreen)

        // Windows and workspaces
        case "window.create":
            return .actions([.createWindow(seed: nil, initialFrame: nil)])
        case "window.toggle-sidebar":
            return .actions([.toggleSidebar(windowID: windowID)])
        case "workspace.create":
            return .actions([.createWorkspace(windowID: windowID, title: nil, activate: true)])
        case "workspace.close":
            guard let workspaceID else { return .none }
            return .ui(.confirmCloseWorkspace(workspaceID: workspaceID))
        case "workspace.rename":
            guard let workspaceID else { return .none }
            return .ui(.renameWorkspace(workspaceID: workspaceID))
        case "workspace.select-previous", "workspace.select-next":
            guard let window = state.window(id: windowID), let workspaceID,
                  let index = window.workspaceIDs.firstIndex(of: workspaceID),
                  window.workspaceIDs.count > 1 else { return .none }
            let step = commandID.hasSuffix("next") ? 1 : -1
            let target = window.workspaceIDs[(index + step + window.workspaceIDs.count) % window.workspaceIDs.count]
            return .actions([.selectWorkspace(windowID: windowID, workspaceID: target)])

        // Tabs
        case "workspace.tab.create":
            return withWorkspace { .createWorkspaceTab(workspaceID: $0, seed: nil) }
        case "workspace.tab.rename":
            guard let workspaceID, let tabID = workspace?.resolvedSelectedTabID else { return .none }
            return .ui(.renameTab(workspaceID: workspaceID, tabID: tabID))
        case "workspace.tab.close":
            guard let workspaceID, let tabID = workspace?.resolvedSelectedTabID else { return .none }
            return .ui(.confirmCloseTab(workspaceID: workspaceID, tabID: tabID))
        case "workspace.tab.select-previous", "workspace.tab.select-next":
            guard let workspace, let workspaceID, let tabID = workspace.resolvedSelectedTabID,
                  let index = workspace.tabIDs.firstIndex(of: tabID), workspace.tabIDs.count > 1 else { return .none }
            let step = commandID.hasSuffix("next") ? 1 : -1
            let target = workspace.tabIDs[(index + step + workspace.tabIDs.count) % workspace.tabIDs.count]
            return .actions([.selectWorkspaceTab(workspaceID: workspaceID, tabID: target)])
        case "workspace.tab.move-left", "workspace.tab.move-right":
            guard let workspace, let workspaceID, let tabID = workspace.resolvedSelectedTabID,
                  let index = workspace.tabIDs.firstIndex(of: tabID) else { return .none }
            let target = index + (commandID.hasSuffix("right") ? 1 : -1)
            guard workspace.tabIDs.indices.contains(target) else { return .none }
            return .actions([.moveWorkspaceTab(workspaceID: workspaceID, fromIndex: index, toIndex: target)])

        // Panes and splits
        case "layout.split.horizontal":
            return withWorkspace { .splitFocusedSlotInDirection(workspaceID: $0, direction: .right) }
        case "layout.split.vertical":
            return withWorkspace { .splitFocusedSlotInDirection(workspaceID: $0, direction: .down) }
        case "layout.split.left":
            return withWorkspace { .splitFocusedSlotInDirection(workspaceID: $0, direction: .left) }
        case "layout.split.up":
            return withWorkspace { .splitFocusedSlotInDirection(workspaceID: $0, direction: .up) }
        case "panel.close":
            guard let focusedPanelID else { return .none }
            return .actions([.closePanel(panelID: focusedPanelID)])
        case "panel.reopen-last-closed":
            return withWorkspace { .reopenLastClosedPanel(workspaceID: $0) }
        case "layout.split.select-previous":
            return withWorkspace { .focusSlot(workspaceID: $0, direction: .previous) }
        case "layout.split.select-next":
            return withWorkspace { .focusSlot(workspaceID: $0, direction: .next) }
        case "layout.split.navigate-left":
            return withWorkspace { .focusSlot(workspaceID: $0, direction: .left) }
        case "layout.split.navigate-right":
            return withWorkspace { .focusSlot(workspaceID: $0, direction: .right) }
        case "layout.split.navigate-up":
            return withWorkspace { .focusSlot(workspaceID: $0, direction: .up) }
        case "layout.split.navigate-down":
            return withWorkspace { .focusSlot(workspaceID: $0, direction: .down) }
        case "layout.split.resize-left":
            return withWorkspace { .resizeFocusedSlotSplit(workspaceID: $0, direction: .left, amount: resizeAmount) }
        case "layout.split.resize-right":
            return withWorkspace { .resizeFocusedSlotSplit(workspaceID: $0, direction: .right, amount: resizeAmount) }
        case "layout.split.resize-up":
            return withWorkspace { .resizeFocusedSlotSplit(workspaceID: $0, direction: .up, amount: resizeAmount) }
        case "layout.split.resize-down":
            return withWorkspace { .resizeFocusedSlotSplit(workspaceID: $0, direction: .down, amount: resizeAmount) }
        case "layout.split.equalize":
            return withWorkspace { .equalizeLayoutSplits(workspaceID: $0) }
        case "panel.focus-mode.toggle":
            return withWorkspace { .toggleFocusedPanelMode(workspaceID: $0) }

        // Right panel
        case "window.toggle-right-panel":
            return withWorkspace { .toggleRightAuxPanel(workspaceID: $0) }
        case "right-panel.tab.select-previous":
            return withWorkspace { .selectAdjacentRightAuxPanelTab(workspaceID: $0, direction: .previous) }
        case "right-panel.tab.select-next":
            return withWorkspace { .selectAdjacentRightAuxPanelTab(workspaceID: $0, direction: .next) }
        case "browser.create":
            return withWorkspace {
                .createWebPanel(workspaceID: $0, panel: WebPanelState(definition: .browser), placement: .rightPanel)
            }
        case "browser.tab.create":
            return withWorkspace {
                .createWebPanel(workspaceID: $0, panel: WebPanelState(definition: .browser), placement: .newTab)
            }
        case "browser.split.create":
            return withWorkspace {
                .createWebPanel(workspaceID: $0, panel: WebPanelState(definition: .browser), placement: .splitRight)
            }

        // Sessions and attention
        case "panel.focus-next-unread-or-active":
            guard let workspace, let workspaceID, let tabID = workspace.resolvedSelectedTabID,
                  let target = state.nextUnreadPanel(
                      fromWindowID: windowID,
                      workspaceID: workspaceID,
                      tabID: tabID,
                      focusedPanelID: focusedPanelID
                  ) else {
                return .app(commandID)
            }
            var actions: [AppAction] = []
            if target.windowID != windowID { actions.append(.selectWindow(windowID: target.windowID)) }
            actions.append(.selectWorkspace(windowID: target.windowID, workspaceID: target.workspaceID))
            actions.append(.selectWorkspaceTab(workspaceID: target.workspaceID, tabID: target.tabID))
            actions.append(.focusPanel(workspaceID: target.workspaceID, panelID: target.panelID))
            return .actions(actions)
        case "terminal.agent-reads.toggle":
            guard let focusedPanelID, case .terminal(let terminal)? = tab?.panels[focusedPanelID] else { return .none }
            return .actions([.setTerminalPanelAgentReadPolicy(
                panelID: focusedPanelID,
                policy: terminal.allowsAgentReads ? .denied : nil
            )])

        // Text size: terminals scale per window; web panels zoom per panel.
        case "text-size.increase", "text-size.decrease", "text-size.reset":
            if let panelTargetID, case .web(let web)? = panelTarget, web.definition == .browser {
                switch commandID {
                case "text-size.increase": return .actions([.increaseBrowserPanelPageZoom(panelID: panelTargetID)])
                case "text-size.decrease": return .actions([.decreaseBrowserPanelPageZoom(panelID: panelTargetID)])
                default: return .actions([.resetBrowserPanelPageZoom(panelID: panelTargetID)])
                }
            }
            // Local documents scale with the window's Markdown text scale.
            if case .web(let web)? = panelTarget, web.definition == .localDocument {
                switch commandID {
                case "text-size.increase": return .actions([.increaseWindowMarkdownTextScale(windowID: windowID)])
                case "text-size.decrease": return .actions([.decreaseWindowMarkdownTextScale(windowID: windowID)])
                default: return .actions([.resetWindowMarkdownTextScale(windowID: windowID)])
                }
            }
            switch commandID {
            case "text-size.increase": return .actions([.increaseWindowTerminalFont(windowID: windowID)])
            case "text-size.decrease": return .actions([.decreaseWindowTerminalFont(windowID: windowID)])
            default: return .actions([.resetWindowTerminalFont(windowID: windowID)])
            }

        // Panel-hosted commands.
        case "find.show", "find.next", "find.previous", "find.hide",
             "terminal.copy", "terminal.paste",
             "browser.location.focus", "browser.reload", "browser.annotate.toggle",
             "local-document.edit", "local-document.save":
            guard let panelTargetID else { return .none }
            return .ui(.panel(commandID: commandID, panelID: panelTargetID))

        default:
            return LinuxCommandTable.binding(commandID) == nil ? .none : .app(commandID)
        }
    }

    private static func suffixNumber(_ commandID: String, prefix: String) -> Int? {
        guard commandID.hasPrefix(prefix) else { return nil }
        guard let number = Int(commandID.dropFirst(prefix.count)), number >= 1 else { return nil }
        return number
    }
}
