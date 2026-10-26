import Foundation

/// Where a binding's accelerator is handled.
public enum LinuxShortcutScope: String, Sendable {
    /// Matched in the window's capture phase before the focused widget sees
    /// the key, so it wins over the terminal. Registered as a GTK
    /// accelerator too, so menus and the shortcuts dialog show it.
    case global
    /// Handled by the focused panel (browser, local document) only. Never
    /// intercepted from a terminal: Ctrl+L, Ctrl+R, Ctrl+E and Ctrl+S belong
    /// to the shell when a terminal has focus.
    case panel
    /// Handled by the terminal widget itself (clipboard).
    case terminal
}

/// Sections of the keyboard shortcuts dialog, ordered as shown.
public enum LinuxShortcutSection: String, CaseIterable, Sendable {
    case application = "Application"
    case windowsAndWorkspaces = "Windows and Workspaces"
    case tabs = "Tabs"
    case panesAndSplits = "Panes and Splits"
    case rightPanel = "Right Panel"
    case attention = "Sessions and Attention"
    case findAndText = "Find and Text"
    case browserAndDocuments = "Browser and Documents"
}

/// One Toastty command on Linux: its stable command ID (the macOS
/// `ToasttyBuiltInCommand.id` when one exists), its title, and its Ubuntu
/// accelerators in GTK syntax (`gtk_accelerator_parse`). The first
/// accelerator is the primary one shown in labels.
public struct LinuxCommandBinding: Equatable, Sendable {
    public let id: String
    public let title: String
    public let accelerators: [String]
    public let scope: LinuxShortcutScope
    public let section: LinuxShortcutSection
    /// The macOS shortcut this replaces, for docs and the parity test.
    public let macOSShortcut: String?
    public let keywords: [String]
    /// Listed in the command palette.
    public let inPalette: Bool

    public init(
        _ id: String,
        _ title: String,
        _ accelerators: [String] = [],
        scope: LinuxShortcutScope = .global,
        section: LinuxShortcutSection,
        macOS: String? = nil,
        keywords: [String] = [],
        inPalette: Bool = true
    ) {
        self.id = id
        self.title = title
        self.accelerators = accelerators
        self.scope = scope
        self.section = section
        self.macOSShortcut = macOS
        self.keywords = keywords
        self.inPalette = inPalette
    }

    /// GAction name (without the `win.`/`app.` prefix). Command IDs already
    /// use only characters `g_action_name_is_valid` accepts.
    public var actionName: String { id }

    public var primaryAccelerator: String? { accelerators.first }
}

/// The single source of truth for Linux command IDs, titles and keyboard
/// shortcuts. Menus, the command palette, the shortcuts dialog, GAction
/// accelerators and the capture-phase key controller all read this table.
///
/// Ubuntu mapping follows GNOME Terminal / Ptyxis conventions: terminals own
/// plain `Ctrl+<letter>`, so app shortcuts use `Ctrl+Shift`, `Ctrl+Alt`,
/// `Ctrl+PageUp/Down` and F-keys (docs/plans/linux-port.md).
public enum LinuxCommandTable {
    public static let digitKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    public static let all: [LinuxCommandBinding] = {
        var bindings: [LinuxCommandBinding] = [
            // MARK: Application
            .init("command-palette.toggle", "Command Palette", ["<Control><Shift>p"], section: .application,
                  macOS: "Cmd+Shift+P", keywords: ["command", "palette", "search"], inPalette: false),
            .init("app.preferences", "Preferences", ["<Control>comma"], section: .application,
                  macOS: "Cmd+,", keywords: ["preferences", "settings", "options"]),
            .init("app.shortcuts", "Keyboard Shortcuts", ["<Control>question"], section: .application,
                  keywords: ["keyboard", "shortcuts", "help", "keys"]),
            .init("app.quit", "Quit", ["<Control><Shift>q"], section: .application,
                  macOS: "Cmd+Q", keywords: ["quit", "exit"]),
            .init("window.fullscreen", "Toggle Fullscreen", ["F11"], section: .application,
                  macOS: "Cmd+Ctrl+F", keywords: ["fullscreen", "window"]),
            .init("app.config.manage", "Manage Config", section: .application,
                  keywords: ["manage", "open", "configuration", "config", "settings", "preferences", "toastty", "toml"]),
            .init("app.reload-configuration", "Reload Configuration", section: .application,
                  keywords: ["reload", "configuration", "config", "preferences"]),
            .init("terminal.profiles.manage", "Manage Terminal Profiles", section: .application,
                  keywords: ["manage", "open", "terminal", "profiles", "config", "toml"]),
            .init("agent.profiles.manage", "Manage Agents", section: .application,
                  keywords: ["manage", "open", "agents", "agent", "profiles", "config", "toml"]),
            .init("agent.toastty-skills.manage", "Manage Toastty Skills", section: .application,
                  keywords: ["manage", "toastty", "codex", "claude", "skills", "plugin", "repair", "uninstall"]),
            .init("agent.status-hooks.setup", "Set Up Agent Status Hooks", section: .application,
                  keywords: ["agent", "status", "hooks", "setup", "codex", "claude", "telemetry"]),
            .init("app.remote-access.open", "Open Remote Access", section: .application,
                  keywords: ["remote", "access", "open", "pair", "pairing", "mobile", "iphone", "tailscale"]),
            .init("diagnostics.snippet.copy", "Send Diagnostics", section: .application,
                  keywords: ["diagnostics", "diagnostic", "report", "logs", "collect", "send", "support", "developer"]),
            .init("help.getting-started", "Get Started", section: .application,
                  keywords: ["getting", "started", "help", "onboarding", "guide", "welcome"]),
            .init("app.about", "About Toastty", section: .application, keywords: ["about", "version"]),

            // MARK: Windows and workspaces
            .init("window.create", "New Window", ["<Control><Shift>n"], section: .windowsAndWorkspaces,
                  macOS: "Cmd+N", keywords: ["window", "new", "create"]),
            .init("window.toggle-sidebar", "Toggle Sidebar", ["F9"], section: .windowsAndWorkspaces,
                  macOS: "Cmd+B", keywords: ["sidebar", "toggle", "show", "hide"]),
            .init("workspace.create", "New Workspace", ["<Control><Alt>n"], section: .windowsAndWorkspaces,
                  macOS: "Cmd+Shift+N", keywords: ["workspace", "new", "create"]),
            .init("workspace.close", "Close Workspace", ["<Control><Alt>w"], section: .windowsAndWorkspaces,
                  macOS: "Cmd+Shift+W", keywords: ["workspace", "close", "remove"]),
            .init("workspace.rename", "Rename Workspace", ["F2"], section: .windowsAndWorkspaces,
                  macOS: "Cmd+Shift+E", keywords: ["workspace", "rename", "edit", "title"]),
            .init("workspace.select-previous", "Previous Workspace", section: .windowsAndWorkspaces,
                  macOS: "Option+Shift+[", keywords: ["workspace", "previous"]),
            .init("workspace.select-next", "Next Workspace", section: .windowsAndWorkspaces,
                  macOS: "Option+Shift+]", keywords: ["workspace", "next"]),
            .init("navigation.back", "Go Back", section: .windowsAndWorkspaces,
                  keywords: ["back", "previous", "history", "navigation", "return"]),
            .init("navigation.forward", "Go Forward", section: .windowsAndWorkspaces,
                  keywords: ["forward", "history", "navigation"]),
            .init("workspace.merge", "Run Merge Button", ["<Alt><Shift>m"], section: .windowsAndWorkspaces,
                  macOS: "Option+Shift+M", keywords: ["merge", "pull", "request", "subspace", "task"]),

            // MARK: Tabs
            .init("workspace.tab.create", "New Tab", ["<Control><Shift>t"], section: .tabs,
                  macOS: "Cmd+T", keywords: ["tab", "new", "create"]),
            .init("workspace.tab.rename", "Rename Tab", ["<Shift>F2"], section: .tabs,
                  macOS: "Option+Shift+E", keywords: ["tab", "rename", "edit", "title"]),
            .init("workspace.tab.close", "Close Tab", section: .tabs, keywords: ["tab", "close"]),
            .init("workspace.tab.select-previous", "Select Previous Tab", ["<Control>Page_Up"], section: .tabs,
                  macOS: "Cmd+Shift+[", keywords: ["tab", "previous", "left", "back"]),
            .init("workspace.tab.select-next", "Select Next Tab", ["<Control>Page_Down"], section: .tabs,
                  macOS: "Cmd+Shift+]", keywords: ["tab", "next", "right", "forward"]),
            .init("workspace.tab.move-left", "Move Tab Left", ["<Control><Shift>Page_Up"], section: .tabs,
                  keywords: ["tab", "move", "left", "reorder"]),
            .init("workspace.tab.move-right", "Move Tab Right", ["<Control><Shift>Page_Down"], section: .tabs,
                  keywords: ["tab", "move", "right", "reorder"]),
            .init("browser.tab.create", "New Browser Tab", ["<Control><Alt><Shift>b"], section: .tabs,
                  macOS: "Cmd+Ctrl+Shift+B", keywords: ["browser", "tab", "new", "create", "web"]),
            .init("local-document.open-tab", "Open Local File in Tab", section: .tabs,
                  keywords: ["open", "local", "file", "document", "tab", "markdown"]),

            // MARK: Panes and splits
            .init("layout.split.horizontal", "Split Right", ["<Control><Shift>o"], section: .panesAndSplits,
                  macOS: "Cmd+D", keywords: ["split", "right", "horizontal", "panel"]),
            .init("layout.split.vertical", "Split Down", ["<Control><Shift>e"], section: .panesAndSplits,
                  macOS: "Cmd+Shift+D", keywords: ["split", "down", "vertical", "panel"]),
            .init("layout.split.left", "Split Left", section: .panesAndSplits,
                  keywords: ["split", "left", "panel"]),
            .init("layout.split.up", "Split Up", section: .panesAndSplits,
                  keywords: ["split", "up", "panel"]),
            .init("panel.close", "Close Panel", ["<Control><Shift>w"], section: .panesAndSplits,
                  macOS: "Cmd+W", keywords: ["close", "panel", "remove"]),
            .init("layout.split.select-previous", "Select Previous Split", ["<Control><Alt>bracketleft"],
                  section: .panesAndSplits, macOS: "Cmd+[", keywords: ["split", "previous", "pane", "panel", "back"]),
            .init("layout.split.select-next", "Select Next Split", ["<Control><Alt>bracketright"],
                  section: .panesAndSplits, macOS: "Cmd+]", keywords: ["split", "next", "pane", "panel", "forward"]),
            .init("layout.split.navigate-left", "Navigate Left", ["<Alt>Left"], section: .panesAndSplits,
                  macOS: "Cmd+Opt+Left", keywords: ["navigate", "split", "left", "pane", "panel", "focus"]),
            .init("layout.split.navigate-right", "Navigate Right", ["<Alt>Right"], section: .panesAndSplits,
                  macOS: "Cmd+Opt+Right", keywords: ["navigate", "split", "right", "pane", "panel", "focus"]),
            .init("layout.split.navigate-up", "Navigate Up", ["<Alt>Up"], section: .panesAndSplits,
                  macOS: "Cmd+Opt+Up", keywords: ["navigate", "split", "up", "pane", "panel", "focus"]),
            .init("layout.split.navigate-down", "Navigate Down", ["<Alt>Down"], section: .panesAndSplits,
                  macOS: "Cmd+Opt+Down", keywords: ["navigate", "split", "down", "pane", "panel", "focus"]),
            .init("layout.split.resize-left", "Resize Left", ["<Control><Shift>Left"], section: .panesAndSplits,
                  macOS: "Cmd+Ctrl+Left", keywords: ["resize", "split", "left", "layout", "panel"]),
            .init("layout.split.resize-right", "Resize Right", ["<Control><Shift>Right"], section: .panesAndSplits,
                  macOS: "Cmd+Ctrl+Right", keywords: ["resize", "split", "right", "layout", "panel"]),
            .init("layout.split.resize-up", "Resize Up", ["<Control><Shift>Up"], section: .panesAndSplits,
                  macOS: "Cmd+Ctrl+Up", keywords: ["resize", "split", "up", "layout", "panel"]),
            .init("layout.split.resize-down", "Resize Down", ["<Control><Shift>Down"], section: .panesAndSplits,
                  macOS: "Cmd+Ctrl+Down", keywords: ["resize", "split", "down", "layout", "panel"]),
            .init("layout.split.equalize", "Equalize Splits", ["<Control><Alt>equal"], section: .panesAndSplits,
                  macOS: "Cmd+Ctrl+=", keywords: ["equalize", "split", "splits", "layout", "balance", "panel"]),
            .init("panel.focus-mode.toggle", "Focus Panel", ["<Control><Shift>x"], section: .panesAndSplits,
                  macOS: "Cmd+Shift+F", keywords: ["focus", "panel", "layout", "restore", "zoom"]),
            .init("panel.reopen-last-closed", "Reopen Closed Panel", section: .panesAndSplits,
                  keywords: ["reopen", "closed", "panel", "undo"]),
            .init("browser.split.create", "New Browser Split", section: .panesAndSplits,
                  keywords: ["browser", "split", "new", "create", "web"]),
            .init("local-document.open-split", "Open Local File in Split", section: .panesAndSplits,
                  keywords: ["open", "local", "file", "document", "split", "markdown"]),

            // MARK: Right panel
            .init("window.toggle-right-panel", "Toggle Right Panel", ["<Shift>F9"], section: .rightPanel,
                  macOS: "Cmd+Shift+B", keywords: ["right", "panel", "sidebar", "toggle", "show", "hide"]),
            .init("right-panel.tab.select-previous", "Select Previous Right Panel Tab", ["<Control><Alt>Page_Up"],
                  section: .rightPanel, macOS: "Cmd+Ctrl+[", keywords: ["right", "panel", "tab", "previous", "left", "back"]),
            .init("right-panel.tab.select-next", "Select Next Right Panel Tab", ["<Control><Alt>Page_Down"],
                  section: .rightPanel, macOS: "Cmd+Ctrl+]", keywords: ["right", "panel", "tab", "next", "right", "forward"]),
            .init("browser.create", "New Browser", ["<Control><Alt>b"], section: .rightPanel,
                  macOS: "Cmd+Ctrl+B", keywords: ["browser", "new", "create", "web"]),
            .init("scratchpad.create", "New Scratchpad", ["<Control><Alt>s"], section: .rightPanel,
                  macOS: "Cmd+Ctrl+S", keywords: ["scratchpad", "new", "create", "visual", "canvas", "diagram", "wireframe"]),
            .init("scratchpad.show-current-session", "Show Scratchpad For Current Session", section: .rightPanel,
                  keywords: ["scratchpad", "show", "current", "session", "agent", "visual"]),
            .init("local-document.open", "Open Local File", section: .rightPanel,
                  keywords: ["open", "local", "file", "document", "code", "markdown", "yaml", "toml", "json"]),

            // MARK: Sessions and attention
            .init("panel.focus-next-unread-or-active", "Jump to Next Active", ["<Control><Shift>j"], section: .attention,
                  macOS: "Cmd+Shift+A", keywords: ["jump", "next", "active", "unread", "attention", "panel"]),
            .init("session.later-flag.toggle", "Flag for Later", ["<Control><Shift>l"], section: .attention,
                  macOS: "Cmd+Shift+L", keywords: ["later", "flag", "session", "remind"]),
            .init("panel.process-watch.create", "Watch Running Command", ["<Control><Shift>m"], section: .attention,
                  macOS: "Cmd+Shift+M", keywords: ["watch", "running", "command", "process", "monitor", "foreground", "terminal", "panel"]),
            .init("terminal.agent-reads.toggle", "Make Terminal Private to Agents", section: .attention,
                  keywords: ["terminal", "private", "agents", "read", "allow", "eye"]),

            // MARK: Find and text
            .init("find.show", "Find", ["<Control><Shift>f"], section: .findAndText,
                  macOS: "Cmd+F", keywords: ["find", "search"]),
            .init("find.next", "Find Next", ["<Control><Shift>g", "F3"], section: .findAndText,
                  macOS: "Cmd+G", keywords: ["find", "next"]),
            .init("find.previous", "Find Previous", ["<Control><Shift>h", "<Shift>F3"], section: .findAndText,
                  macOS: "Cmd+Shift+G", keywords: ["find", "previous"]),
            .init("find.hide", "Hide Find", section: .findAndText, keywords: ["find", "hide", "close"]),
            .init("terminal.copy", "Copy", ["<Control><Shift>c"], scope: .terminal, section: .findAndText,
                  macOS: "Cmd+C", keywords: ["copy", "clipboard"], inPalette: false),
            .init("terminal.paste", "Paste", ["<Control><Shift>v", "<Shift>Insert"], scope: .terminal, section: .findAndText,
                  macOS: "Cmd+V", keywords: ["paste", "clipboard"], inPalette: false),
            .init("text-size.increase", "Increase Text Size", ["<Control>plus", "<Control>equal", "<Control>KP_Add"],
                  section: .findAndText, macOS: "Cmd+=", keywords: ["text", "size", "zoom", "bigger", "font"]),
            .init("text-size.decrease", "Decrease Text Size", ["<Control>minus", "<Control>KP_Subtract"],
                  section: .findAndText, macOS: "Cmd+-", keywords: ["text", "size", "zoom", "smaller", "font"]),
            .init("text-size.reset", "Reset Text Size", ["<Control>0", "<Control>KP_0"],
                  section: .findAndText, macOS: "Cmd+0", keywords: ["text", "size", "zoom", "reset", "font"]),

            // MARK: Browser and documents (panel-scoped: never stolen from a terminal)
            .init("browser.location.focus", "Open Location", ["<Control>l"], scope: .panel, section: .browserAndDocuments,
                  macOS: "Cmd+L", keywords: ["browser", "location", "url", "address"]),
            .init("browser.reload", "Reload Page", ["<Control>r", "F5"], scope: .panel, section: .browserAndDocuments,
                  macOS: "Cmd+R", keywords: ["browser", "reload", "refresh"]),
            .init("browser.annotate.toggle", "Annotate Browser Page", ["<Control><Shift>a"], scope: .panel,
                  section: .browserAndDocuments,
                  keywords: ["browser", "annotate", "annotation", "comment", "mark", "feedback", "screenshot", "agent"]),
            .init("local-document.edit", "Edit Document", ["<Control>e"], scope: .panel, section: .browserAndDocuments,
                  macOS: "Cmd+E", keywords: ["document", "edit"]),
            .init("local-document.save", "Save Document", ["<Control>s"], scope: .panel, section: .browserAndDocuments,
                  macOS: "Cmd+S", keywords: ["document", "save"]),
        ]

        for (index, digit) in digitKeys.enumerated() {
            let number = index + 1
            bindings.append(.init(
                "workspace.tab.select-\(number)", "Switch to Tab \(number)", ["<Alt>\(digit)"],
                section: .tabs, macOS: "Cmd+\(digit)", keywords: ["tab", "switch", "\(number)"], inPalette: false
            ))
        }
        for (index, digit) in digitKeys.enumerated() {
            let number = index + 1
            bindings.append(.init(
                "workspace.select-\(number)", "Switch to Workspace \(number)", ["<Control><Alt>\(digit)"],
                section: .windowsAndWorkspaces, macOS: "Option+\(digit)", keywords: ["workspace", "switch", "\(number)"],
                inPalette: false
            ))
        }
        for (index, digit) in (digitKeys + ["0"]).enumerated() {
            let number = index + 1
            bindings.append(.init(
                "layout.pane.focus-\(number)", "Focus Pane \(number)", ["<Alt><Shift>\(digit)"],
                section: .panesAndSplits, macOS: "Option+Shift+\(digit)", keywords: ["pane", "focus", "\(number)"],
                inPalette: false
            ))
        }
        return bindings
    }()

    public static let byID: [String: LinuxCommandBinding] = {
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    public static func binding(_ id: String) -> LinuxCommandBinding? { byID[id] }

    public static func title(_ id: String) -> String { byID[id]?.title ?? id }

    public static var globalBindings: [LinuxCommandBinding] {
        all.filter { $0.scope == .global && $0.accelerators.isEmpty == false }
    }

    /// macOS `ToasttyBuiltInCommand` IDs whose macOS shortcut intentionally
    /// has no Ubuntu accelerator. Empty today; the parity test fails if a
    /// built-in shortcut is dropped without being listed here.
    public static let macOSShortcutsWithoutLinuxAccelerator: Set<String> = []

    /// Modifier+key combinations reserved for app shortcuts; agent and
    /// terminal profile `shortcutKey`s that would collide are reported
    /// through the profile shortcut conflict path instead of being bound.
    public static let reservedProfileKeys: Set<String> = ["n", "w", "b", "s", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    /// Accelerator for an agent profile launch (`Ctrl+Alt+key`) or a
    /// terminal-profile split down (`Ctrl+Alt+Shift+key`).
    public static func profileAccelerator(shortcutKey: String, splitDown: Bool) -> String? {
        let key = shortcutKey.lowercased()
        guard key.count == 1, reservedProfileKeys.contains(key) == false else { return nil }
        return splitDown ? "<Control><Alt><Shift>\(key)" : "<Control><Alt>\(key)"
    }
}
