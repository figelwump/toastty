import CoreState
import Foundation

enum AppControlActionID: String, CaseIterable, Sendable {
    case windowCreate = "window.create"
    case windowSidebarToggle = "window.sidebar.toggle"
    case workspaceCreate = "workspace.create"
    case workspaceSelect = "workspace.select"
    case workspaceRename = "workspace.rename"
    case workspaceClose = "workspace.close"
    case workspaceTabCreate = "workspace.tab.create"
    case workspaceTabSelect = "workspace.tab.select"
    case workspaceTabSelectPrevious = "workspace.tab.select-previous"
    case workspaceTabSelectNext = "workspace.tab.select-next"
    case workspaceTabRename = "workspace.tab.rename"
    case workspaceTabClose = "workspace.tab.close"
    case workspaceReopenLastClosedPanel = "workspace.reopen-last-closed-panel"
    case panelFocusNextUnreadOrActive = "panel.focus-next-unread-or-active"
    case workspaceSplitHorizontal = "workspace.split.horizontal"
    case workspaceSplitVertical = "workspace.split.vertical"
    case workspaceSplitRight = "workspace.split.right"
    case workspaceSplitDown = "workspace.split.down"
    case workspaceSplitLeft = "workspace.split.left"
    case workspaceSplitUp = "workspace.split.up"
    case workspaceSplitRightWithProfile = "workspace.split.right.with-profile"
    case workspaceSplitDownWithProfile = "workspace.split.down.with-profile"
    case panelClose = "panel.close"
    case workspaceFocusSlotPrevious = "workspace.focus-slot.previous"
    case workspaceFocusSlotNext = "workspace.focus-slot.next"
    case workspaceFocusSlotLeft = "workspace.focus-slot.left"
    case workspaceFocusSlotRight = "workspace.focus-slot.right"
    case workspaceFocusSlotUp = "workspace.focus-slot.up"
    case workspaceFocusSlotDown = "workspace.focus-slot.down"
    case workspaceFocusPanel = "workspace.focus-panel"
    case workspaceResizeSplitLeft = "workspace.resize-split.left"
    case workspaceResizeSplitRight = "workspace.resize-split.right"
    case workspaceResizeSplitUp = "workspace.resize-split.up"
    case workspaceResizeSplitDown = "workspace.resize-split.down"
    case workspaceEqualizeSplits = "workspace.equalize-splits"
    case panelCreateBrowser = "panel.create.browser"
    case panelCreateLocalDocument = "panel.create.local-document"
    case panelLocalDocumentSearchStart = "panel.local-document.search.start"
    case panelLocalDocumentSearchUpdateQuery = "panel.local-document.search.update-query"
    case panelLocalDocumentSearchNext = "panel.local-document.search.next"
    case panelLocalDocumentSearchPrevious = "panel.local-document.search.previous"
    case panelLocalDocumentSearchHide = "panel.local-document.search.hide"
    case panelFocusModeToggle = "panel.focus-mode.toggle"
    case appFontIncrease = "app.font.increase"
    case appFontDecrease = "app.font.decrease"
    case appFontReset = "app.font.reset"
    case appMarkdownTextIncrease = "app.markdown-text.increase"
    case appMarkdownTextDecrease = "app.markdown-text.decrease"
    case appMarkdownTextReset = "app.markdown-text.reset"
    case appBrowserZoomIncrease = "app.browser-zoom.increase"
    case appBrowserZoomDecrease = "app.browser-zoom.decrease"
    case appBrowserZoomReset = "app.browser-zoom.reset"
    case agentLaunch = "agent.launch"
    case configReload = "config.reload"
    case terminalSendText = "terminal.send-text"
    case terminalDropImageFiles = "terminal.drop-image-files"

    static func resolve(_ rawValue: String) -> Self? {
        if let action = Self(rawValue: rawValue) {
            return action
        }
        return allCases.first { $0.aliases.contains(rawValue) }
    }

    var aliases: [String] {
        switch self {
        case .windowSidebarToggle:
            return ["window.toggle-sidebar"]
        case .workspaceCreate:
            return ["sidebar.workspaces.new"]
        case .workspaceTabCreate:
            return ["workspace.tab.new"]
        case .panelFocusNextUnreadOrActive:
            return ["workspace.focus-next-unread-or-active"]
        case .panelClose:
            return ["workspace.close-focused-panel"]
        case .panelCreateLocalDocument:
            return ["panel.create.localDocument", "panel.create.markdown"]
        case .panelLocalDocumentSearchStart:
            return ["panel.markdown.search.start"]
        case .panelLocalDocumentSearchUpdateQuery:
            return ["panel.markdown.search.update-query"]
        case .panelLocalDocumentSearchNext:
            return ["panel.markdown.search.next"]
        case .panelLocalDocumentSearchPrevious:
            return ["panel.markdown.search.previous"]
        case .panelLocalDocumentSearchHide:
            return ["panel.markdown.search.hide"]
        case .panelFocusModeToggle:
            return ["topbar.toggle.focused-panel"]
        case .appMarkdownTextIncrease:
            return ["app.markdown_text.increase"]
        case .appMarkdownTextDecrease:
            return ["app.markdown_text.decrease"]
        case .appMarkdownTextReset:
            return ["app.markdown_text.reset"]
        case .appBrowserZoomIncrease:
            return ["app.browser_zoom.increase"]
        case .appBrowserZoomDecrease:
            return ["app.browser_zoom.decrease"]
        case .appBrowserZoomReset:
            return ["app.browser_zoom.reset"]
        default:
            return []
        }
    }

    var descriptor: AppControlCommandDescriptor {
        switch self {
        case .windowCreate:
            return .init(id: rawValue, kind: .action, summary: "Create a new window.", selectors: [.windowID])
        case .windowSidebarToggle:
            return .init(id: rawValue, kind: .action, summary: "Toggle sidebar visibility for a window.", selectors: [.windowID], aliases: aliases)
        case .workspaceCreate:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Create a workspace in a window.",
                selectors: [.windowID],
                parameters: [.title(required: false), .activate(required: false)],
                aliases: aliases
            )
        case .workspaceSelect:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Select a workspace by ID or 1-based index.",
                selectors: [.windowID, .workspaceID],
                parameters: [.index(summary: "1-based workspace index in the target window.", required: false)]
            )
        case .workspaceRename:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Rename a workspace.",
                selectors: [.windowID, .workspaceID],
                parameters: [.title(required: true)]
            )
        case .workspaceClose:
            return .init(id: rawValue, kind: .action, summary: "Close a workspace.", selectors: [.windowID, .workspaceID])
        case .workspaceTabCreate:
            return .init(id: rawValue, kind: .action, summary: "Create a new workspace tab.", selectors: [.windowID, .workspaceID], aliases: aliases)
        case .workspaceTabSelect:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Select a tab by ID or 1-based index.",
                selectors: [.windowID, .workspaceID],
                parameters: [.tabID(required: false), .index(summary: "1-based tab index in the target workspace.", required: false)]
            )
        case .workspaceTabSelectPrevious:
            return .init(id: rawValue, kind: .action, summary: "Select the previous tab in the target workspace.", selectors: [.windowID, .workspaceID])
        case .workspaceTabSelectNext:
            return .init(id: rawValue, kind: .action, summary: "Select the next tab in the target workspace.", selectors: [.windowID, .workspaceID])
        case .workspaceTabRename:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Rename the selected or explicit tab.",
                selectors: [.windowID, .workspaceID],
                parameters: [.tabID(required: false), .index(summary: "1-based tab index in the target workspace.", required: false), .title(required: true)]
            )
        case .workspaceTabClose:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Close the selected or explicit tab.",
                selectors: [.windowID, .workspaceID],
                parameters: [.tabID(required: false), .index(summary: "1-based tab index in the target workspace.", required: false)]
            )
        case .workspaceReopenLastClosedPanel:
            return .init(id: rawValue, kind: .action, summary: "Reopen the most recently closed panel.", selectors: [.windowID, .workspaceID])
        case .panelFocusNextUnreadOrActive:
            return .init(id: rawValue, kind: .action, summary: "Focus the next unread or active session panel.", selectors: [.windowID], aliases: aliases)
        case .workspaceSplitHorizontal:
            return .init(id: rawValue, kind: .action, summary: "Split the focused slot horizontally.", selectors: [.windowID, .workspaceID])
        case .workspaceSplitVertical:
            return .init(id: rawValue, kind: .action, summary: "Split the focused slot vertically.", selectors: [.windowID, .workspaceID])
        case .workspaceSplitRight:
            return .init(id: rawValue, kind: .action, summary: "Split the focused slot to the right.", selectors: [.windowID, .workspaceID])
        case .workspaceSplitDown:
            return .init(id: rawValue, kind: .action, summary: "Split the focused slot downward.", selectors: [.windowID, .workspaceID])
        case .workspaceSplitLeft:
            return .init(id: rawValue, kind: .action, summary: "Split the focused slot to the left.", selectors: [.windowID, .workspaceID])
        case .workspaceSplitUp:
            return .init(id: rawValue, kind: .action, summary: "Split the focused slot upward.", selectors: [.windowID, .workspaceID])
        case .workspaceSplitRightWithProfile:
            return .init(id: rawValue, kind: .action, summary: "Split right with a terminal profile.", selectors: [.windowID, .workspaceID], parameters: [.profileID(required: true)])
        case .workspaceSplitDownWithProfile:
            return .init(id: rawValue, kind: .action, summary: "Split down with a terminal profile.", selectors: [.windowID, .workspaceID], parameters: [.profileID(required: true)])
        case .panelClose:
            return .init(id: rawValue, kind: .action, summary: "Close the focused panel.", selectors: [.windowID, .workspaceID], aliases: aliases)
        case .workspaceFocusSlotPrevious:
            return .init(id: rawValue, kind: .action, summary: "Focus the previous slot.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusSlotNext:
            return .init(id: rawValue, kind: .action, summary: "Focus the next slot.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusSlotLeft:
            return .init(id: rawValue, kind: .action, summary: "Focus the slot to the left.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusSlotRight:
            return .init(id: rawValue, kind: .action, summary: "Focus the slot to the right.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusSlotUp:
            return .init(id: rawValue, kind: .action, summary: "Focus the slot above.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusSlotDown:
            return .init(id: rawValue, kind: .action, summary: "Focus the slot below.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusPanel:
            return .init(id: rawValue, kind: .action, summary: "Focus a panel by panel ID.", selectors: [.windowID, .workspaceID], parameters: [.panelID(required: true)])
        case .workspaceResizeSplitLeft:
            return .init(id: rawValue, kind: .action, summary: "Resize the focused split to the left.", selectors: [.windowID, .workspaceID], parameters: [.amount(required: false)])
        case .workspaceResizeSplitRight:
            return .init(id: rawValue, kind: .action, summary: "Resize the focused split to the right.", selectors: [.windowID, .workspaceID], parameters: [.amount(required: false)])
        case .workspaceResizeSplitUp:
            return .init(id: rawValue, kind: .action, summary: "Resize the focused split upward.", selectors: [.windowID, .workspaceID], parameters: [.amount(required: false)])
        case .workspaceResizeSplitDown:
            return .init(id: rawValue, kind: .action, summary: "Resize the focused split downward.", selectors: [.windowID, .workspaceID], parameters: [.amount(required: false)])
        case .workspaceEqualizeSplits:
            return .init(id: rawValue, kind: .action, summary: "Equalize split ratios in the target workspace.", selectors: [.windowID, .workspaceID])
        case .panelCreateBrowser:
            return .init(id: rawValue, kind: .action, summary: "Create a browser panel.", selectors: [.windowID, .workspaceID], parameters: [.placement(required: false), .url(required: false)])
        case .panelCreateLocalDocument:
            return .init(id: rawValue, kind: .action, summary: "Open a local document panel.", selectors: [.windowID, .workspaceID], parameters: [.filePath(required: true), .placement(required: false)], aliases: aliases)
        case .panelLocalDocumentSearchStart:
            return .init(id: rawValue, kind: .action, summary: "Show find for a local-document panel.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .panelLocalDocumentSearchUpdateQuery:
            return .init(id: rawValue, kind: .action, summary: "Update the active local-document find query.", selectors: [.windowID, .workspaceID, .panelID], parameters: [.query(required: true)], aliases: aliases)
        case .panelLocalDocumentSearchNext:
            return .init(id: rawValue, kind: .action, summary: "Advance to the next local-document find match.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .panelLocalDocumentSearchPrevious:
            return .init(id: rawValue, kind: .action, summary: "Move to the previous local-document find match.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .panelLocalDocumentSearchHide:
            return .init(id: rawValue, kind: .action, summary: "Hide find for a local-document panel.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .panelFocusModeToggle:
            return .init(id: rawValue, kind: .action, summary: "Toggle focused panel mode.", selectors: [.windowID, .workspaceID], aliases: aliases)
        case .appFontIncrease:
            return .init(id: rawValue, kind: .action, summary: "Increase terminal font size for a window.", selectors: [.windowID])
        case .appFontDecrease:
            return .init(id: rawValue, kind: .action, summary: "Decrease terminal font size for a window.", selectors: [.windowID])
        case .appFontReset:
            return .init(id: rawValue, kind: .action, summary: "Reset terminal font size for a window.", selectors: [.windowID])
        case .appMarkdownTextIncrease:
            return .init(id: rawValue, kind: .action, summary: "Increase local-document text scale for a window.", selectors: [.windowID], aliases: aliases)
        case .appMarkdownTextDecrease:
            return .init(id: rawValue, kind: .action, summary: "Decrease local-document text scale for a window.", selectors: [.windowID], aliases: aliases)
        case .appMarkdownTextReset:
            return .init(id: rawValue, kind: .action, summary: "Reset local-document text scale for a window.", selectors: [.windowID], aliases: aliases)
        case .appBrowserZoomIncrease:
            return .init(id: rawValue, kind: .action, summary: "Increase browser zoom for a browser panel.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .appBrowserZoomDecrease:
            return .init(id: rawValue, kind: .action, summary: "Decrease browser zoom for a browser panel.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .appBrowserZoomReset:
            return .init(id: rawValue, kind: .action, summary: "Reset browser zoom for a browser panel.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .agentLaunch:
            return .init(id: rawValue, kind: .action, summary: "Launch an agent profile into a terminal panel.", selectors: [.workspaceID, .panelID], parameters: [.profileID(required: true)])
        case .configReload:
            return .init(id: rawValue, kind: .action, summary: "Reload Toastty configuration and profiles.", selectors: [])
        case .terminalSendText:
            return .init(id: rawValue, kind: .action, summary: "Send text to a terminal panel.", selectors: [.windowID, .workspaceID, .panelID], parameters: [.text(required: true), .submit(required: false), .allowUnavailable(required: false)])
        case .terminalDropImageFiles:
            return .init(id: rawValue, kind: .action, summary: "Drop image files into a terminal panel.", selectors: [.windowID, .workspaceID, .panelID], parameters: [.files(required: true), .cwd(required: false), .allowUnavailable(required: false)])
        }
    }
}

enum AppControlQueryID: String, CaseIterable, Sendable {
    case workspaceSnapshot = "workspace.snapshot"
    case terminalState = "terminal.state"
    case terminalVisibleText = "terminal.visible-text"
    case panelLocalDocumentState = "panel.local-document.state"
    case panelBrowserState = "panel.browser.state"

    static func resolve(_ rawValue: String) -> Self? {
        if let query = Self(rawValue: rawValue) {
            return query
        }
        return allCases.first { $0.aliases.contains(rawValue) }
    }

    var aliases: [String] {
        switch self {
        case .panelLocalDocumentState:
            return ["panel.markdown.state"]
        default:
            return []
        }
    }

    var descriptor: AppControlCommandDescriptor {
        switch self {
        case .workspaceSnapshot:
            return .init(id: rawValue, kind: .query, summary: "Return workspace structure and tab metadata.", selectors: [.windowID, .workspaceID])
        case .terminalState:
            return .init(id: rawValue, kind: .query, summary: "Return terminal state metadata.", selectors: [.windowID, .workspaceID, .panelID])
        case .terminalVisibleText:
            return .init(id: rawValue, kind: .query, summary: "Return the visible text in a terminal panel.", selectors: [.windowID, .workspaceID, .panelID], parameters: [.contains(required: false)])
        case .panelLocalDocumentState:
            return .init(id: rawValue, kind: .query, summary: "Return local-document panel state.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .panelBrowserState:
            return .init(id: rawValue, kind: .query, summary: "Return browser panel state.", selectors: [.windowID, .workspaceID, .panelID])
        }
    }
}

private extension AppControlParameterDescriptor {
    static func activate(required: Bool) -> Self {
        .init(
            name: "activate",
            summary: "Select the new workspace immediately. Defaults to true.",
            valueType: .boolean,
            required: required
        )
    }

    static func amount(required: Bool) -> Self {
        .init(name: "amount", summary: "Positive resize amount.", valueType: .integer, required: required)
    }

    static func allowUnavailable(required: Bool) -> Self {
        .init(name: "allowUnavailable", summary: "Return availability metadata instead of failing when a terminal surface is unavailable.", valueType: .boolean, required: required)
    }

    static func contains(required: Bool) -> Self {
        .init(name: "contains", summary: "Substring to test against visible terminal text.", valueType: .string, required: required)
    }

    static func cwd(required: Bool) -> Self {
        .init(name: "cwd", summary: "Base directory for relative file paths.", valueType: .string, required: required)
    }

    static func filePath(required: Bool) -> Self {
        .init(name: "filePath", summary: "Local file path to open.", valueType: .string, required: required)
    }

    static func files(required: Bool) -> Self {
        .init(name: "files", summary: "Image file path. Repeat to provide multiple paths.", valueType: .string, required: required, repeatable: true)
    }

    static func index(summary: String, required: Bool) -> Self {
        .init(name: "index", summary: summary, valueType: .integer, required: required)
    }

    static func panelID(required: Bool) -> Self {
        .init(name: "panelID", summary: "Panel UUID.", valueType: .uuid, required: required)
    }

    static func placement(required: Bool) -> Self {
        .init(name: "placement", summary: "Panel placement strategy.", valueType: .string, required: required, allowedValues: ["rootRight", "newTab", "splitRight"])
    }

    static func profileID(required: Bool) -> Self {
        .init(name: "profileID", summary: "Agent or terminal profile ID.", valueType: .string, required: required)
    }

    static func query(required: Bool) -> Self {
        .init(name: "query", summary: "Find query. Use an empty string to clear the current query while keeping find visible.", valueType: .string, required: required)
    }

    static func submit(required: Bool) -> Self {
        .init(name: "submit", summary: "Submit the text after sending it.", valueType: .boolean, required: required)
    }

    static func tabID(required: Bool) -> Self {
        .init(name: "tabID", summary: "Workspace tab UUID.", valueType: .uuid, required: required)
    }

    static func text(required: Bool) -> Self {
        .init(name: "text", summary: "Text payload.", valueType: .string, required: required)
    }

    static func title(required: Bool) -> Self {
        .init(name: "title", summary: "Title text.", valueType: .string, required: required)
    }

    static func url(required: Bool) -> Self {
        .init(name: "url", summary: "Initial browser URL.", valueType: .string, required: required)
    }
}
