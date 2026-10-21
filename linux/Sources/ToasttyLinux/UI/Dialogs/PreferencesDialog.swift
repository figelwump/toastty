import CGtk
import CoreState
import Foundation

/// Where `LinuxUIPreferences` persists. The app-logic frontend routes each
/// setting to the store macOS uses (`AppLogicUIPreferenceStorage`); without
/// it (the reducer-only binding) preferences stay in memory.
@MainActor
public protocol LinuxUIPreferenceStorage: AnyObject {
    /// The shared Ask Before Quitting setting (`toastty.askBeforeQuitting`).
    var askBeforeQuitting: Bool { get }
    func setAskBeforeQuitting(_ value: Bool)
    /// Linux-only settings (`toastty.linux.*` keys); nil when unset.
    func bool(forKey key: String) -> Bool?
    func string(forKey key: String) -> String?
    func set(_ value: Bool, forKey key: String)
    func set(_ value: String, forKey key: String)
    /// Applies and persists the default terminal font size
    /// (`terminal-font-size` in the Toastty config).
    func setDefaultTerminalFontSize(points: Double)
}

/// UI preferences the GTK shell owns. Loaded from `storage` when created
/// (build it before the first window, so nothing shows defaults first);
/// every change writes through to it.
@MainActor
public final class LinuxUIPreferences {
    /// UserDefaults keys for settings macOS does not have.
    public enum Key {
        public static let colorScheme = "toastty.linux.colorScheme"
        public static let showsShortcutHintsWithAlt = "toastty.linux.showsShortcutHintsWithAlt"
        public static let tabBarAutohide = "toastty.linux.tabBarAutohide"
    }

    private let storage: (any LinuxUIPreferenceStorage)?

    public var colorScheme: LinuxColorSchemePreference {
        didSet {
            LinuxTheme.apply(colorScheme)
            storage?.set(colorScheme.rawValue, forKey: Key.colorScheme)
        }
    }

    private var inMemoryAskBeforeQuitting = true
    /// Reads and writes the shared setting, so the quit confirmation, the
    /// Preferences switch and `AppStore` always agree.
    public var askBeforeQuitting: Bool {
        get { storage?.askBeforeQuitting ?? inMemoryAskBeforeQuitting }
        set {
            if let storage { storage.setAskBeforeQuitting(newValue) } else { inMemoryAskBeforeQuitting = newValue }
        }
    }

    public var showsShortcutHintsWithAlt: Bool {
        didSet { storage?.set(showsShortcutHintsWithAlt, forKey: Key.showsShortcutHintsWithAlt) }
    }

    public var tabBarAutohide: Bool {
        didSet { storage?.set(tabBarAutohide, forKey: Key.tabBarAutohide) }
    }

    /// `TOASTTY_LINUX_COLOR_SCHEME` overrides the stored style for this run
    /// (screenshots) without being saved.
    public init(
        storage: (any LinuxUIPreferenceStorage)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.storage = storage
        colorScheme = environment["TOASTTY_LINUX_COLOR_SCHEME"].flatMap(LinuxColorSchemePreference.init(rawValue:))
            ?? storage?.string(forKey: Key.colorScheme).flatMap(LinuxColorSchemePreference.init(rawValue:))
            ?? .system
        showsShortcutHintsWithAlt = storage?.bool(forKey: Key.showsShortcutHintsWithAlt) ?? true
        tabBarAutohide = storage?.bool(forKey: Key.tabBarAutohide) ?? false
    }

    /// The Terminal page's Default Font Size.
    public func setDefaultTerminalFontSize(points: Double, store: any LinuxStoreBinding) {
        if let storage {
            storage.setDefaultTerminalFontSize(points: points)
        } else {
            store.send(.setConfiguredTerminalFont(points: points))
        }
    }

    /// Script summary keys: the model values, and the style Adwaita applies.
    func summary() -> [String: String] {
        [
            "prefStyle": colorScheme.rawValue,
            "prefAskBeforeQuitting": String(askBeforeQuitting),
            "prefShortcutHints": String(showsShortcutHintsWithAlt),
            "prefTabBarAutohide": String(tabBarAutohide),
            "appliedStyle": LinuxTheme.appliedPreference.rawValue,
        ]
    }

    static func format(points: Double) -> String {
        abs(points.rounded() - points) < 0.0001 ? String(Int(points.rounded())) : String(format: "%.2f", points)
    }
}

/// `AdwPreferencesDialog` with General, Terminal, Agents and Remote Access
/// pages, wired to the settings reachable today (UI preferences and
/// `AppState` terminal font); app-logic rows route through commands.
@MainActor
public final class PreferencesDialog {
    /// Builds the Remote Access page (panels-remote `installRemoteAccessUI`).
    public static var remoteAccessPage: ((_ runCommand: @escaping (String) -> Void) -> WidgetPtr?)?
    /// The open dialog (held while presented; scripts drive its rows).
    public private(set) static var current: PreferencesDialog?

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
        Gtk.setName(style, Self.styleRowName)
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
            "Ask Before Quitting", subtitle: "Confirm before closing every window", active: preferences.askBeforeQuitting,
            name: Self.askBeforeQuittingRowName
        ) { preferences.askBeforeQuitting = $0 })
        adw_preferences_group_add(cast(behavior), Self.switchRow(
            "Shortcut Hints", subtitle: "Show workspace shortcuts in the sidebar while Alt is held",
            active: preferences.showsShortcutHintsWithAlt, name: Self.shortcutHintsRowName
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
        Gtk.setName(size, Self.fontSizeRowName)
        Signal.notify(size, "value") {
            preferences.setDefaultTerminalFontSize(points: adw_spin_row_get_value(cast(size)), store: store)
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
        Signal.connect(dialog, "closed") { [weak self] in
            if let self, Self.current === self { Self.current = nil }
        }
        Self.current = self
        adw_dialog_present(cast(dialog), parent)
    }

    // MARK: Automation

    static let styleRowName = "preferences-style"
    static let askBeforeQuittingRowName = "preferences-ask-before-quitting"
    static let shortcutHintsRowName = "preferences-shortcut-hints"
    static let fontSizeRowName = "preferences-default-font-size"

    /// What the open dialog's rows show (`expect prefsDialogStyle=dark`).
    func widgetSummary() -> [String: String] {
        var result: [String: String] = [:]
        if let style = Gtk.find(named: Self.styleRowName, in: dialog) {
            let index = Int(adw_combo_row_get_selected(cast(style)))
            let cases = LinuxColorSchemePreference.allCases
            result["prefsDialogStyle"] = cases.indices.contains(index) ? cases[index].rawValue : "none"
        }
        if let row = Gtk.find(named: Self.askBeforeQuittingRowName, in: dialog) {
            result["prefsDialogAskBeforeQuitting"] = String(adw_switch_row_get_active(cast(row)).bool)
        }
        if let row = Gtk.find(named: Self.shortcutHintsRowName, in: dialog) {
            result["prefsDialogShortcutHints"] = String(adw_switch_row_get_active(cast(row)).bool)
        }
        if let row = Gtk.find(named: Self.fontSizeRowName, in: dialog) {
            result["prefsDialogFontSize"] = LinuxUIPreferences.format(points: adw_spin_row_get_value(cast(row)))
        }
        return result
    }

    /// `preferences <row> <value>` in scripts: changes a row's widget as a
    /// user would, so the row's own signal handler applies it. Returns an
    /// error, else nil.
    func set(row: String, value: String) -> String? {
        switch row {
        case "style":
            guard let style = Gtk.find(named: Self.styleRowName, in: dialog),
                  let index = LinuxColorSchemePreference.allCases.firstIndex(where: { $0.rawValue == value }) else {
                return "no style row, or unknown style \(value)"
            }
            adw_combo_row_set_selected(cast(style), guint(index))
        case "ask-before-quitting", "shortcut-hints":
            let name = row == "shortcut-hints" ? Self.shortcutHintsRowName : Self.askBeforeQuittingRowName
            guard let switchRow = Gtk.find(named: name, in: dialog), value == "on" || value == "off" else {
                return "no \(row) row, or bad value \(value) (on|off)"
            }
            // Activating the row toggles its switch, as a click does.
            if adw_switch_row_get_active(cast(switchRow)).bool != (value == "on") { gtk_widget_activate(switchRow) }
        case "font-size":
            guard let size = Gtk.find(named: Self.fontSizeRowName, in: dialog), let points = Double(value) else {
                return "no font size row, or bad value \(value)"
            }
            adw_spin_row_set_value(cast(size), points)
        default:
            return "unknown preferences row \(row)"
        }
        return nil
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

    private static func switchRow(
        _ title: String, subtitle: String, active: Bool, name: String? = nil, onChange: @escaping (Bool) -> Void
    ) -> WidgetPtr {
        let row = adw_switch_row_new()!
        if let name { Gtk.setName(row, name) }
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
