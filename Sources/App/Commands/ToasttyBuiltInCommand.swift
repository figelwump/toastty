import Foundation

enum ToasttyBuiltInCommand: Equatable, Sendable {
    // This is intentionally limited to the small set of built-ins currently
    // shared between the command palette and menu surfaces. Do not treat it as
    // a universal registry for every app command without revisiting that scope.
    case splitRight
    case splitLeft
    case splitDown
    case splitUp
    case selectPreviousSplit
    case selectNextSplit
    case navigateSplitUp
    case navigateSplitDown
    case navigateSplitLeft
    case navigateSplitRight
    case equalizeSplits
    case resizeSplitLeft
    case resizeSplitRight
    case resizeSplitUp
    case resizeSplitDown
    case newWindow
    case newWorkspace
    case newTab
    case newBrowser
    case newBrowserTab
    case newBrowserSplit
    case openLocalFile
    case openLocalFileInTab
    case openLocalFileInSplit
    case showScratchpadForCurrentSession
    case toggleSidebar
    case toggleRightPanel
    case toggleFocusedPanelMode
    case watchRunningCommand
    case closePanel
    case renameWorkspace
    case closeWorkspace
    case renameTab
    case selectPreviousTab
    case selectNextTab
    case selectPreviousRightPanelTab
    case selectNextRightPanelTab
    case jumpToNextActive
    case manageConfig
    case manageTerminalProfiles
    case manageAgents
    case reloadConfiguration

    private static let showSidebarTitle = "Show Sidebar"
    private static let hideSidebarTitle = "Hide Sidebar"
    private static let showRightPanelTitle = "Show Right Panel"
    private static let hideRightPanelTitle = "Hide Right Panel"
    private static let focusPanelTitle = "Focus Panel"
    private static let restoreLayoutTitle = "Restore Layout"

    // Keep these machine ids stable even if the user-facing titles change.
    var id: String {
        switch self {
        case .splitRight:
            return "layout.split.horizontal"
        case .splitLeft:
            return "layout.split.left"
        case .splitDown:
            return "layout.split.vertical"
        case .splitUp:
            return "layout.split.up"
        case .selectPreviousSplit:
            return "layout.split.select-previous"
        case .selectNextSplit:
            return "layout.split.select-next"
        case .navigateSplitUp:
            return "layout.split.navigate-up"
        case .navigateSplitDown:
            return "layout.split.navigate-down"
        case .navigateSplitLeft:
            return "layout.split.navigate-left"
        case .navigateSplitRight:
            return "layout.split.navigate-right"
        case .equalizeSplits:
            return "layout.split.equalize"
        case .resizeSplitLeft:
            return "layout.split.resize-left"
        case .resizeSplitRight:
            return "layout.split.resize-right"
        case .resizeSplitUp:
            return "layout.split.resize-up"
        case .resizeSplitDown:
            return "layout.split.resize-down"
        case .newWindow:
            return "window.create"
        case .newWorkspace:
            return "workspace.create"
        case .newTab:
            return "workspace.tab.create"
        case .newBrowser:
            return "browser.create"
        case .newBrowserTab:
            return "browser.tab.create"
        case .newBrowserSplit:
            return "browser.split.create"
        case .openLocalFile:
            return "local-document.open"
        case .openLocalFileInTab:
            return "local-document.open-tab"
        case .openLocalFileInSplit:
            return "local-document.open-split"
        case .showScratchpadForCurrentSession:
            return "scratchpad.show-current-session"
        case .toggleSidebar:
            return "window.toggle-sidebar"
        case .toggleRightPanel:
            return "window.toggle-right-panel"
        case .toggleFocusedPanelMode:
            return "panel.focus-mode.toggle"
        case .watchRunningCommand:
            return "panel.process-watch.create"
        case .closePanel:
            return "panel.close"
        case .renameWorkspace:
            return "workspace.rename"
        case .closeWorkspace:
            return "workspace.close"
        case .renameTab:
            return "workspace.tab.rename"
        case .selectPreviousTab:
            return "workspace.tab.select-previous"
        case .selectNextTab:
            return "workspace.tab.select-next"
        case .selectPreviousRightPanelTab:
            return "right-panel.tab.select-previous"
        case .selectNextRightPanelTab:
            return "right-panel.tab.select-next"
        case .jumpToNextActive:
            return "panel.focus-next-unread-or-active"
        case .manageConfig:
            return "app.config.manage"
        case .manageTerminalProfiles:
            return "terminal.profiles.manage"
        case .manageAgents:
            return "agent.profiles.manage"
        case .reloadConfiguration:
            return "app.reload-configuration"
        }
    }

    var title: String {
        switch self {
        case .splitRight:
            return "Split Right"
        case .splitLeft:
            return "Split Left"
        case .splitDown:
            return "Split Down"
        case .splitUp:
            return "Split Up"
        case .selectPreviousSplit:
            return "Select Previous Split"
        case .selectNextSplit:
            return "Select Next Split"
        case .navigateSplitUp:
            return "Navigate Up"
        case .navigateSplitDown:
            return "Navigate Down"
        case .navigateSplitLeft:
            return "Navigate Left"
        case .navigateSplitRight:
            return "Navigate Right"
        case .equalizeSplits:
            return "Equalize Splits"
        case .resizeSplitLeft:
            return "Resize Left"
        case .resizeSplitRight:
            return "Resize Right"
        case .resizeSplitUp:
            return "Resize Up"
        case .resizeSplitDown:
            return "Resize Down"
        case .newWindow:
            return "New Window"
        case .newWorkspace:
            return "New Workspace"
        case .newTab:
            return "New Tab"
        case .newBrowser:
            return "New Browser"
        case .newBrowserTab:
            return "New Browser Tab"
        case .newBrowserSplit:
            return "New Browser Split"
        case .openLocalFile:
            return "Open Local File"
        case .openLocalFileInTab:
            return "Open Local File in Tab"
        case .openLocalFileInSplit:
            return "Open Local File in Split"
        case .showScratchpadForCurrentSession:
            return "Show Scratchpad For Current Session"
        case .toggleSidebar:
            return Self.showSidebarTitle
        case .toggleRightPanel:
            return Self.showRightPanelTitle
        case .toggleFocusedPanelMode:
            return Self.focusPanelTitle
        case .watchRunningCommand:
            return "Watch Running Command"
        case .closePanel:
            return "Close Panel"
        case .renameWorkspace:
            return "Rename Workspace"
        case .closeWorkspace:
            return "Close Workspace"
        case .renameTab:
            return "Rename Tab"
        case .selectPreviousTab:
            return "Select Previous Tab"
        case .selectNextTab:
            return "Select Next Tab"
        case .selectPreviousRightPanelTab:
            return "Select Previous Right Panel Tab"
        case .selectNextRightPanelTab:
            return "Select Next Right Panel Tab"
        case .jumpToNextActive:
            return "Jump to Next Active"
        case .manageConfig:
            return "Manage Config"
        case .manageTerminalProfiles:
            return "Manage Terminal Profiles"
        case .manageAgents:
            return "Manage Agents"
        case .reloadConfiguration:
            return "Reload Configuration"
        }
    }

    var shortcut: ToasttyKeyboardShortcut? {
        switch self {
        case .splitRight:
            return ToasttyKeyboardShortcuts.splitHorizontal
        case .splitLeft:
            return nil
        case .splitDown:
            return ToasttyKeyboardShortcuts.splitVertical
        case .splitUp:
            return nil
        case .selectPreviousSplit:
            return ToasttyKeyboardShortcuts.focusPreviousPane
        case .selectNextSplit:
            return ToasttyKeyboardShortcuts.focusNextPane
        case .navigateSplitUp:
            return ToasttyKeyboardShortcuts.focusPaneUp
        case .navigateSplitDown:
            return ToasttyKeyboardShortcuts.focusPaneDown
        case .navigateSplitLeft:
            return ToasttyKeyboardShortcuts.focusPaneLeft
        case .navigateSplitRight:
            return ToasttyKeyboardShortcuts.focusPaneRight
        case .equalizeSplits:
            return ToasttyKeyboardShortcuts.equalizeSplits
        case .resizeSplitLeft:
            return ToasttyKeyboardShortcuts.resizeSplitLeft
        case .resizeSplitRight:
            return ToasttyKeyboardShortcuts.resizeSplitRight
        case .resizeSplitUp:
            return ToasttyKeyboardShortcuts.resizeSplitUp
        case .resizeSplitDown:
            return ToasttyKeyboardShortcuts.resizeSplitDown
        case .newWindow:
            return ToasttyKeyboardShortcuts.newWindow
        case .newWorkspace:
            return ToasttyKeyboardShortcuts.newWorkspace
        case .newTab:
            return ToasttyKeyboardShortcuts.newTab
        case .newBrowser:
            return ToasttyKeyboardShortcuts.newBrowser
        case .newBrowserTab:
            return ToasttyKeyboardShortcuts.newBrowserTab
        case .newBrowserSplit:
            return nil
        case .openLocalFile:
            return nil
        case .openLocalFileInTab:
            return nil
        case .openLocalFileInSplit:
            return nil
        case .showScratchpadForCurrentSession:
            return nil
        case .toggleSidebar:
            return ToasttyKeyboardShortcuts.toggleSidebar
        case .toggleRightPanel:
            return ToasttyKeyboardShortcuts.toggleRightPanel
        case .toggleFocusedPanelMode:
            return ToasttyKeyboardShortcuts.toggleFocusedPanel
        case .watchRunningCommand:
            return ToasttyKeyboardShortcuts.watchRunningCommand
        case .closePanel:
            return ToasttyKeyboardShortcuts.closePanel
        case .renameWorkspace:
            return ToasttyKeyboardShortcuts.renameWorkspace
        case .closeWorkspace:
            return ToasttyKeyboardShortcuts.closeWorkspace
        case .renameTab:
            return ToasttyKeyboardShortcuts.renameTab
        case .selectPreviousTab:
            return ToasttyKeyboardShortcuts.selectPreviousTab
        case .selectNextTab:
            return ToasttyKeyboardShortcuts.selectNextTab
        case .selectPreviousRightPanelTab:
            return ToasttyKeyboardShortcuts.selectPreviousRightPanelTab
        case .selectNextRightPanelTab:
            return ToasttyKeyboardShortcuts.selectNextRightPanelTab
        case .jumpToNextActive:
            return ToasttyKeyboardShortcuts.focusNextUnreadOrActivePanel
        case .manageConfig:
            return nil
        case .manageTerminalProfiles:
            return nil
        case .manageAgents:
            return nil
        case .reloadConfiguration:
            return nil
        }
    }

    var requiredShortcut: ToasttyKeyboardShortcut {
        guard let shortcut else {
            preconditionFailure("Missing required shortcut metadata for \(id)")
        }
        return shortcut
    }

    var keywords: [String] {
        switch self {
        case .splitRight:
            return ["split", "right", "horizontal", "panel"]
        case .splitLeft:
            return ["split", "left", "panel"]
        case .splitDown:
            return ["split", "down", "vertical", "panel"]
        case .splitUp:
            return ["split", "up", "panel"]
        case .selectPreviousSplit:
            return ["split", "previous", "pane", "panel", "back"]
        case .selectNextSplit:
            return ["split", "next", "pane", "panel", "forward"]
        case .navigateSplitUp:
            return ["navigate", "split", "up", "pane", "panel", "focus"]
        case .navigateSplitDown:
            return ["navigate", "split", "down", "pane", "panel", "focus"]
        case .navigateSplitLeft:
            return ["navigate", "split", "left", "pane", "panel", "focus"]
        case .navigateSplitRight:
            return ["navigate", "split", "right", "pane", "panel", "focus"]
        case .equalizeSplits:
            return ["equalize", "split", "splits", "layout", "balance", "panel"]
        case .resizeSplitLeft:
            return ["resize", "split", "left", "layout", "panel"]
        case .resizeSplitRight:
            return ["resize", "split", "right", "layout", "panel"]
        case .resizeSplitUp:
            return ["resize", "split", "up", "layout", "panel"]
        case .resizeSplitDown:
            return ["resize", "split", "down", "layout", "panel"]
        case .newWindow:
            return ["window", "new", "create"]
        case .newWorkspace:
            return ["workspace", "new", "create"]
        case .newTab:
            return ["tab", "new", "create"]
        case .newBrowser:
            return ["browser", "new", "create", "web"]
        case .newBrowserTab:
            return ["browser", "tab", "new", "create", "web"]
        case .newBrowserSplit:
            return ["browser", "split", "new", "create", "web"]
        case .openLocalFile:
            return ["open", "local", "file", "document", "code", "markdown", "yaml", "toml", "json", "xml", "shell", "config", "csv", "tsv"]
        case .openLocalFileInTab:
            return ["open", "local", "file", "document", "tab", "code", "markdown", "yaml", "toml", "json", "xml", "shell", "config", "csv", "tsv"]
        case .openLocalFileInSplit:
            return ["open", "local", "file", "document", "split", "code", "markdown", "yaml", "toml", "json", "xml", "shell", "config", "csv", "tsv"]
        case .showScratchpadForCurrentSession:
            return ["scratchpad", "show", "current", "session", "agent", "visual"]
        case .toggleSidebar:
            return ["sidebar", "toggle", "show", "hide"]
        case .toggleRightPanel:
            return ["right", "panel", "sidebar", "toggle", "show", "hide"]
        case .toggleFocusedPanelMode:
            return ["focus", "panel", "layout", "restore"]
        case .watchRunningCommand:
            return ["watch", "running", "command", "process", "monitor", "foreground", "terminal", "panel"]
        case .closePanel:
            return ["close", "panel", "remove"]
        case .renameWorkspace:
            return ["workspace", "rename", "edit", "title"]
        case .closeWorkspace:
            return ["workspace", "close", "remove"]
        case .renameTab:
            return ["tab", "rename", "edit", "title"]
        case .selectPreviousTab:
            return ["tab", "previous", "left", "back"]
        case .selectNextTab:
            return ["tab", "next", "right", "forward"]
        case .selectPreviousRightPanelTab:
            return ["right", "panel", "tab", "previous", "left", "back"]
        case .selectNextRightPanelTab:
            return ["right", "panel", "tab", "next", "right", "forward"]
        case .jumpToNextActive:
            return ["jump", "next", "active", "unread", "attention", "panel"]
        case .manageConfig:
            return ["manage", "open", "configuration", "config", "settings", "preferences", "toastty", "toml"]
        case .manageTerminalProfiles:
            return ["manage", "open", "terminal", "profiles", "config", "toml"]
        case .manageAgents:
            return ["manage", "open", "agents", "agent", "profiles", "config", "toml"]
        case .reloadConfiguration:
            return ["reload", "configuration", "config", "preferences"]
        }
    }

    static func toggleSidebarTitle(sidebarVisible: Bool) -> String {
        sidebarVisible ? hideSidebarTitle : showSidebarTitle
    }

    static func toggleRightPanelTitle(rightPanelVisible: Bool) -> String {
        rightPanelVisible ? hideRightPanelTitle : showRightPanelTitle
    }

    static func toggleFocusedPanelModeTitle(focusedPanelModeActive: Bool) -> String {
        focusedPanelModeActive ? restoreLayoutTitle : focusPanelTitle
    }
}
