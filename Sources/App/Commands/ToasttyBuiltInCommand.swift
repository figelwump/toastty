import Foundation

enum ToasttyBuiltInCommand {
    // This is intentionally limited to the small set of built-ins currently
    // shared between the command palette and menu surfaces. Do not treat it as
    // a universal registry for every app command without revisiting that scope.
    case splitRight
    case splitDown
    case selectPreviousSplit
    case selectNextSplit
    case navigateSplitUp
    case navigateSplitDown
    case navigateSplitLeft
    case navigateSplitRight
    case equalizeSplits
    case newWindow
    case newWorkspace
    case newTab
    case toggleSidebar
    case closePanel
    case renameWorkspace
    case closeWorkspace
    case renameTab
    case selectPreviousTab
    case selectNextTab
    case jumpToNextActive
    case reloadConfiguration

    private static let showSidebarTitle = "Show Sidebar"
    private static let hideSidebarTitle = "Hide Sidebar"

    // Keep these machine ids stable even if the user-facing titles change.
    var id: String {
        switch self {
        case .splitRight:
            return "layout.split.horizontal"
        case .splitDown:
            return "layout.split.vertical"
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
        case .newWindow:
            return "window.create"
        case .newWorkspace:
            return "workspace.create"
        case .newTab:
            return "workspace.tab.create"
        case .toggleSidebar:
            return "window.toggle-sidebar"
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
        case .jumpToNextActive:
            return "panel.focus-next-unread-or-active"
        case .reloadConfiguration:
            return "app.reload-configuration"
        }
    }

    var title: String {
        switch self {
        case .splitRight:
            return "Split Right"
        case .splitDown:
            return "Split Down"
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
        case .newWindow:
            return "New Window"
        case .newWorkspace:
            return "New Workspace"
        case .newTab:
            return "New Tab"
        case .toggleSidebar:
            return Self.showSidebarTitle
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
        case .jumpToNextActive:
            return "Jump to Next Active"
        case .reloadConfiguration:
            return "Reload Configuration"
        }
    }

    var shortcut: ToasttyKeyboardShortcut? {
        switch self {
        case .splitRight:
            return ToasttyKeyboardShortcuts.splitHorizontal
        case .splitDown:
            return ToasttyKeyboardShortcuts.splitVertical
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
        case .newWindow:
            return ToasttyKeyboardShortcuts.newWindow
        case .newWorkspace:
            return ToasttyKeyboardShortcuts.newWorkspace
        case .newTab:
            return ToasttyKeyboardShortcuts.newTab
        case .toggleSidebar:
            return ToasttyKeyboardShortcuts.toggleSidebar
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
        case .jumpToNextActive:
            return ToasttyKeyboardShortcuts.focusNextUnreadOrActivePanel
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
        case .splitDown:
            return ["split", "down", "vertical", "panel"]
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
        case .newWindow:
            return ["window", "new", "create"]
        case .newWorkspace:
            return ["workspace", "new", "create"]
        case .newTab:
            return ["tab", "new", "create"]
        case .toggleSidebar:
            return ["sidebar", "toggle", "show", "hide"]
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
        case .jumpToNextActive:
            return ["jump", "next", "active", "unread", "attention", "panel"]
        case .reloadConfiguration:
            return ["reload", "configuration", "config", "preferences"]
        }
    }

    static func toggleSidebarTitle(sidebarVisible: Bool) -> String {
        sidebarVisible ? hideSidebarTitle : showSidebarTitle
    }
}
