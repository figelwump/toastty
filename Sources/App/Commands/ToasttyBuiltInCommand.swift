import Foundation

enum ToasttyBuiltInCommand {
    // This is intentionally limited to the small set of built-ins currently
    // shared between the command palette and menu surfaces. Do not treat it as
    // a universal registry for every app command without revisiting that scope.
    case splitRight
    case splitDown
    case newWorkspace
    case newTab
    case toggleSidebar
    case closePanel
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
        case .newWorkspace:
            return "workspace.create"
        case .newTab:
            return "workspace.tab.create"
        case .toggleSidebar:
            return "window.toggle-sidebar"
        case .closePanel:
            return "panel.close"
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
        case .newWorkspace:
            return "New Workspace"
        case .newTab:
            return "New Tab"
        case .toggleSidebar:
            return Self.showSidebarTitle
        case .closePanel:
            return "Close Panel"
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
        case .newWorkspace:
            return ToasttyKeyboardShortcuts.newWorkspace
        case .newTab:
            return ToasttyKeyboardShortcuts.newTab
        case .toggleSidebar:
            return ToasttyKeyboardShortcuts.toggleSidebar
        case .closePanel:
            return ToasttyKeyboardShortcuts.closePanel
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
        case .newWorkspace:
            return ["workspace", "new", "create"]
        case .newTab:
            return ["tab", "new", "create"]
        case .toggleSidebar:
            return ["sidebar", "toggle", "show", "hide"]
        case .closePanel:
            return ["close", "panel", "remove"]
        case .reloadConfiguration:
            return ["reload", "configuration", "config", "preferences"]
        }
    }

    static func toggleSidebarTitle(sidebarVisible: Bool) -> String {
        sidebarVisible ? hideSidebarTitle : showSidebarTitle
    }
}
