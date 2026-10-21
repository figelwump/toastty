import CGtk
import CoreState
import Foundation

/// UI preferences the GTK shell owns directly. Kept in memory until the
/// app-logic layer brings `~/.toastty` config persistence to Linux.
@MainActor
public final class LinuxUIPreferences {
    public var colorScheme: LinuxColorSchemePreference = .system {
        didSet { LinuxTheme.apply(colorScheme) }
    }
    public var askBeforeQuitting = true
    public var showsShortcutHintsWithAlt = true
    public var tabBarAutohide = false

    public init() {
        if let raw = ProcessInfo.processInfo.environment["TOASTTY_LINUX_COLOR_SCHEME"],
           let scheme = LinuxColorSchemePreference(rawValue: raw) {
            colorScheme = scheme
        }
    }
}

/// `AdwPreferencesDialog` with General, Terminal, Agents and Remote Access
/// pages, wired to the settings reachable today (UI preferences and
/// `AppState` terminal font); app-logic rows route through commands.
@MainActor
public final class PreferencesDialog {
    /// Builds the Remote Access page (panels-remote `installRemoteAccessUI`).
    public static var remoteAccessPage: ((_ runCommand: @escaping (String) -> Void) -> WidgetPtr?)?

    public let dialog: WidgetPtr
    private let ref: GObjectRef

    public init(
        preferences: LinuxUIPreferences,
        store: any LinuxStoreBinding,
        runCommand: @escaping (String) -> Void
    ) {
        dialog = widget(adw_preferences_dialog_new())
        ref = GObjectRef(sinking: dialog)
        adw_preferences_dialog_set_search_enabled(cast(dialog), 1)

        // General
        let general = Self.page("General", icon: "preferences-system-symbolic")
        let appearance = Self.group("Appearance", description: nil)
        let style = adw_combo_row_new()!
        adw_preferences_row_set_title(cast(style), "Style")
        adw_action_row_set_subtitle(cast(style), "Accent color follows the system")
        let styles = gtk_string_list_new(nil)!
        for option in LinuxColorSchemePreference.allCases { gtk_string_list_append(styles, option.title) }
        adw_combo_row_set_model(cast(style), styles)
        g_object_unref(UnsafeMutableRawPointer(styles))
        adw_combo_row_set_selected(cast(style), guint(LinuxColorSchemePreference.allCases.firstIndex(of: preferences.colorScheme) ?? 0))
        Signal.notify(style, "selected") {
            let index = Int(adw_combo_row_get_selected(cast(style)))
            if LinuxColorSchemePreference.allCases.indices.contains(index) {
                preferences.colorScheme = LinuxColorSchemePreference.allCases[index]
            }
        }
        adw_preferences_group_add(cast(appearance), style)
        adw_preferences_page_add(cast(general), cast(appearance))

        let behavior = Self.group("Behavior", description: nil)
        adw_preferences_group_add(cast(behavior), Self.switchRow(
            "Ask Before Quitting", subtitle: "Confirm before closing every window", active: preferences.askBeforeQuitting
        ) { preferences.askBeforeQuitting = $0 })
        adw_preferences_group_add(cast(behavior), Self.switchRow(
            "Shortcut Hints", subtitle: "Show workspace shortcuts in the sidebar while Alt is held",
            active: preferences.showsShortcutHintsWithAlt
        ) { preferences.showsShortcutHintsWithAlt = $0 })
        adw_preferences_group_add(cast(behavior), Self.actionRow(
            "Manage Config", subtitle: "~/.toastty/config", icon: "document-edit-symbolic"
        ) { runCommand("app.config.manage") })
        adw_preferences_page_add(cast(general), cast(behavior))
        adw_preferences_dialog_add(cast(dialog), cast(general))

        // Terminal
        let terminal = Self.page("Terminal", icon: "utilities-terminal-symbolic")
        let font = Self.group("Font", description: "Ghostty config still decides the font family and colors")
        let size = adw_spin_row_new_with_range(AppState.minTerminalFontPoints, AppState.maxTerminalFontPoints, AppState.terminalFontStepPoints)!
        adw_preferences_row_set_title(cast(size), "Default Font Size")
        adw_action_row_set_subtitle(cast(size), "Points; per-window size changes with Ctrl+plus and Ctrl+minus")
        adw_spin_row_set_value(cast(size), store.state.configuredTerminalFontBaselinePoints)
        Signal.notify(size, "value") {
            store.send(.setConfiguredTerminalFont(points: adw_spin_row_get_value(cast(size))))
        }
        adw_preferences_group_add(cast(font), size)
        adw_preferences_page_add(cast(terminal), cast(font))
        let profiles = Self.group("Profiles", description: nil)
        adw_preferences_group_add(cast(profiles), Self.actionRow(
            "Terminal Profiles", subtitle: "~/.toastty/terminal-profiles.toml", icon: "document-edit-symbolic"
        ) { runCommand("terminal.profiles.manage") })
        adw_preferences_page_add(cast(terminal), cast(profiles))
        adw_preferences_dialog_add(cast(dialog), cast(terminal))

        // Agents
        let agents = Self.page("Agents", icon: "system-run-symbolic")
        let agentGroup = Self.group("Managed Agents", description: "Agent profiles launch with Ctrl+Alt+key")
        adw_preferences_group_add(cast(agentGroup), Self.actionRow(
            "Manage Agents", subtitle: "~/.toastty/agents.toml", icon: "document-edit-symbolic"
        ) { runCommand("agent.profiles.manage") })
        adw_preferences_group_add(cast(agentGroup), Self.actionRow(
            "Agent Status Hooks", subtitle: "Report Claude Code and Codex status to the sidebar", icon: "go-next-symbolic"
        ) { runCommand("agent.status-hooks.setup") })
        adw_preferences_group_add(cast(agentGroup), Self.actionRow(
            "Toastty Skills", subtitle: "Install, repair or remove Toastty's agent skills", icon: "go-next-symbolic"
        ) { runCommand("agent.toastty-skills.manage") })
        adw_preferences_page_add(cast(agents), cast(agentGroup))
        adw_preferences_dialog_add(cast(dialog), cast(agents))

        // Remote Access (replaced by the app-logic page when installed).
        if let provider = Self.remoteAccessPage, let page = provider(runCommand) {
            adw_preferences_dialog_add(cast(dialog), cast(page))
            return
        }
        let remote = Self.page("Remote Access", icon: "network-wireless-symbolic")
        let remoteGroup = Self.group(
            "Remote Access",
            description: "Follow and answer agent sessions from the Toastty iOS app over Tailscale."
        )
        let enable = Self.switchRow("Enable Remote Access", subtitle: "Available once the gateway is ported to Linux", active: false) { _ in }
        gtk_widget_set_sensitive(enable, 0)
        adw_preferences_group_add(cast(remoteGroup), enable)
        adw_preferences_group_add(cast(remoteGroup), Self.actionRow(
            "Pair a Device", subtitle: "Show the pairing code", icon: "go-next-symbolic"
        ) { runCommand("app.remote-access.open") })
        adw_preferences_page_add(cast(remote), cast(remoteGroup))
        adw_preferences_dialog_add(cast(dialog), cast(remote))
    }

    public func present(over parent: WidgetPtr) {
        adw_dialog_present(cast(dialog), parent)
    }

    private static func page(_ title: String, icon: String) -> WidgetPtr {
        let page = adw_preferences_page_new()!
        adw_preferences_page_set_title(cast(page), title)
        adw_preferences_page_set_icon_name(cast(page), icon)
        return page
    }

    private static func group(_ title: String, description: String?) -> WidgetPtr {
        let group = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(group), title)
        if let description { adw_preferences_group_set_description(cast(group), description) }
        return group
    }

    private static func switchRow(_ title: String, subtitle: String, active: Bool, onChange: @escaping (Bool) -> Void) -> WidgetPtr {
        let row = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(row), title)
        adw_action_row_set_subtitle(cast(row), subtitle)
        adw_switch_row_set_active(cast(row), active.gboolean)
        Signal.notify(row, "active") { onChange(adw_switch_row_get_active(cast(row)).bool) }
        return row
    }

    private static func actionRow(_ title: String, subtitle: String, icon: String, onActivate: @escaping () -> Void) -> WidgetPtr {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(cast(row), title)
        adw_action_row_set_subtitle(cast(row), subtitle)
        adw_action_row_add_suffix(cast(row), Gtk.image(icon))
        gtk_list_box_row_set_activatable(cast(row), 1)
        Signal.connect(row, "activated") { onActivate() }
        return row
    }
}

/// Keyboard shortcuts help (`AdwShortcutsDialog`), generated from
/// `LinuxCommandTable`.
@MainActor
public enum ShortcutsDialog {
    public static func make() -> WidgetPtr {
        let dialog = adw_shortcuts_dialog_new()!
        for section in LinuxShortcutSection.allCases {
            let sectionWidget = adw_shortcuts_section_new(section.rawValue)!
            var added = Set<String>()
            for binding in LinuxCommandTable.all where binding.section == section && binding.accelerators.isEmpty == false {
                let family = numberedFamily(binding.id)
                if let family {
                    guard added.insert(family.key).inserted else { continue }
                    adw_shortcuts_section_add(sectionWidget, adw_shortcuts_item_new(family.title, family.accelerators))
                } else {
                    let accelerators = binding.accelerators.joined(separator: " ")
                    adw_shortcuts_section_add(sectionWidget, adw_shortcuts_item_new(binding.title, accelerators))
                }
            }
            adw_shortcuts_dialog_add(cast(dialog), sectionWidget)
        }
        return widget(dialog)
    }

    /// Collapses `workspace.tab.select-1…9` style families into one row.
    static func numberedFamily(_ id: String) -> (key: String, title: String, accelerators: String)? {
        let families: [(prefix: String, title: String, first: String, last: String)] = [
            ("workspace.tab.select-", "Switch to Tab 1–9", "<Alt>1", "<Alt>9"),
            ("workspace.select-", "Switch to Workspace 1–9", "<Control><Alt>1", "<Control><Alt>9"),
            ("layout.pane.focus-", "Focus Pane 1–10", "<Alt><Shift>1", "<Alt><Shift>0"),
        ]
        for family in families where id.hasPrefix(family.prefix) && Int(id.dropFirst(family.prefix.count)) != nil {
            return (family.prefix, family.title, "\(family.first)...\(family.last)")
        }
        return nil
    }
}

@MainActor
public enum AboutDialog {
    public static func present(over parent: WidgetPtr) {
        let about = adw_about_dialog_new()!
        adw_about_dialog_set_application_name(cast(about), "Toastty")
        adw_about_dialog_set_application_icon(cast(about), AppIcon.name)
        adw_about_dialog_set_developer_name(cast(about), "Giant Things")
        adw_about_dialog_set_version(cast(about), ProcessInfo.processInfo.environment["TOASTTY_VERSION"] ?? "0.1.0 (Linux preview)")
        adw_about_dialog_set_comments(cast(about), "A terminal workspace for running and following coding agents.")
        adw_about_dialog_set_website(cast(about), "https://github.com/figelwump/toastty")
        adw_dialog_present(cast(about), parent)
    }
}
