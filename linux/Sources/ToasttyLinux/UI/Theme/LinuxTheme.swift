import CGtk
import Foundation

public enum LinuxColorSchemePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var adwScheme: AdwColorScheme {
        switch self {
        case .system: return ADW_COLOR_SCHEME_DEFAULT
        case .light: return ADW_COLOR_SCHEME_FORCE_LIGHT
        case .dark: return ADW_COLOR_SCHEME_FORCE_DARK
        }
    }
}

/// Host chrome styling. Colors come from libadwaita's named colors and CSS
/// variables, so the system accent (Yaru accents on Ubuntu, via the
/// settings portal) and dark/light switching apply without app code.
/// Session status colors mirror the macOS `ToastyTheme` hues.
@MainActor
public enum LinuxTheme {
    private static var provider: OpaquePointer?

    public static func install() {
        guard provider == nil, let display = gdk_display_get_default() else { return }
        let cssProvider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(cssProvider, css)
        gtk_style_context_add_provider_for_display(display, OpaquePointer(cssProvider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        provider = OpaquePointer(cssProvider)
    }

    public static func apply(_ preference: LinuxColorSchemePreference) {
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), preference.adwScheme)
    }

    public static var isDark: Bool {
        adw_style_manager_get_dark(adw_style_manager_get_default()).bool
    }

    /// Name of the current system accent (`blue`, `teal`, … ; Ubuntu's Yaru
    /// accents map onto these through the portal).
    public static var accentName: String {
        switch adw_style_manager_get_accent_color(adw_style_manager_get_default()) {
        case ADW_ACCENT_COLOR_BLUE: return "blue"
        case ADW_ACCENT_COLOR_TEAL: return "teal"
        case ADW_ACCENT_COLOR_GREEN: return "green"
        case ADW_ACCENT_COLOR_YELLOW: return "yellow"
        case ADW_ACCENT_COLOR_ORANGE: return "orange"
        case ADW_ACCENT_COLOR_RED: return "red"
        case ADW_ACCENT_COLOR_PINK: return "pink"
        case ADW_ACCENT_COLOR_PURPLE: return "purple"
        case ADW_ACCENT_COLOR_SLATE: return "slate"
        default: return "unknown"
        }
    }

    public static let css = """
    /* ---- Toastty Linux host chrome ---------------------------------- */
    :root {
      --toastty-working: #e8a635;
      --toastty-approval: #e8a635;
      --toastty-ready: #4fa58a;
      --toastty-error: #e55c5c;
      --toastty-idle: #a8977f;
      --toastty-later: #a77bd6;
      --toastty-card-radius: 12px;
      --toastty-terminal-bg: #1d1d20;
      --toastty-terminal-fg: #e8e4df;
    }

    /* Sidebar */
    .toastty-sidebar { background-color: var(--sidebar-bg-color); }
    .toastty-sidebar list.workspace-list { background: transparent; padding: 4px 6px 10px 6px; }
    .toastty-sidebar list.workspace-list > row {
      background: transparent; padding: 0; margin: 3px 0; border-radius: var(--toastty-card-radius);
      outline-offset: -2px;
    }
    .toastty-sidebar list.workspace-list > row:hover { background: transparent; }
    .workspace-card {
      border-radius: var(--toastty-card-radius);
      padding: 9px 10px 9px 12px;
      background-color: alpha(currentColor, 0.035);
      border: 1px solid alpha(currentColor, 0.05);
      transition: background-color 120ms ease-out, border-color 120ms ease-out;
    }
    .workspace-card:hover { background-color: alpha(currentColor, 0.07); }
    .workspace-card.selected {
      background-color: color-mix(in srgb, var(--accent-bg-color) 16%, transparent);
      border-color: color-mix(in srgb, var(--accent-bg-color) 40%, transparent);
    }
    .workspace-card.drop-target { border-color: var(--accent-color); border-style: dashed; }
    .workspace-card .workspace-title { font-weight: 600; }
    .workspace-card.unvisited .workspace-title { font-weight: 800; }
    .workspace-card .workspace-subtitle { font-size: 0.82em; opacity: 0.62; font-family: monospace; }
    .workspace-card.selected .workspace-subtitle { opacity: 0.78; }

    .session-row { border-radius: 8px; padding: 3px 6px 3px 4px; margin-top: 2px; }
    .session-row:hover { background-color: alpha(currentColor, 0.06); }
    .session-row.focused { background-color: alpha(currentColor, 0.09); }
    .session-row.attention-ready { background-color: color-mix(in srgb, var(--toastty-ready) 14%, transparent); }
    .session-row.attention-approval { background-color: color-mix(in srgb, var(--toastty-approval) 13%, transparent); }
    .session-row.attention-error { background-color: color-mix(in srgb, var(--toastty-error) 13%, transparent); }
    .session-row .session-name { font-size: 0.92em; font-weight: 500; }
    .session-row.unread .session-name { font-weight: 700; }
    .session-row .session-agent { font-size: 0.78em; font-family: monospace; opacity: 0.6; }
    .session-row .session-summary { font-size: 0.82em; opacity: 0.7; }

    .status-dot { min-width: 8px; min-height: 8px; border-radius: 999px; margin: 0 2px; background-color: var(--toastty-idle); }
    .status-dot.working { background-color: var(--toastty-working); }
    .status-dot.needs-approval { background-color: var(--toastty-approval); box-shadow: 0 0 0 3px color-mix(in srgb, var(--toastty-approval) 25%, transparent); }
    .status-dot.ready { background-color: var(--toastty-ready); }
    .status-dot.error { background-color: var(--toastty-error); }
    .status-dot.idle { background-color: var(--toastty-idle); }

    .status-chip { font-size: 0.72em; font-weight: 700; border-radius: 6px; padding: 0 6px; }
    .status-chip.needs-approval { color: var(--toastty-approval); background-color: color-mix(in srgb, var(--toastty-approval) 16%, transparent); }
    .status-chip.error { color: var(--toastty-error); background-color: color-mix(in srgb, var(--toastty-error) 14%, transparent); }
    .status-chip.ready { color: var(--toastty-ready); background-color: color-mix(in srgb, var(--toastty-ready) 14%, transparent); }

    .later-flag { color: var(--toastty-later); }

    .count-badge {
      font-size: 0.75em; font-weight: 700; min-width: 16px; min-height: 16px; padding: 0 5px;
      border-radius: 999px; background-color: var(--accent-bg-color); color: var(--accent-fg-color);
    }
    .count-badge.quiet { background-color: alpha(currentColor, 0.12); color: inherit; }

    .shortcut-hint {
      font-family: monospace; font-size: 0.74em; font-weight: 600;
      padding: 1px 6px; border-radius: 6px;
      background-color: alpha(currentColor, 0.1); border: 1px solid alpha(currentColor, 0.12);
    }

    /* Workspace content */
    .workspace-content { background-color: var(--window-bg-color); }
    .split-root { padding: 6px; }
    paned.toastty-split > separator { background: transparent; min-width: 6px; min-height: 6px; }
    paned.toastty-split > separator:hover { background-color: alpha(var(--accent-bg-color), 0.25); }
    .split-resize-handle { background: transparent; }
    .split-resize-handle:hover { background-color: alpha(var(--accent-bg-color), 0.25); }

    .panel-frame {
      border-radius: var(--toastty-card-radius);
      background-color: var(--toastty-terminal-bg);
      color: var(--toastty-terminal-fg);
      border: 1px solid alpha(black, 0.18);
      box-shadow: 0 1px 2px alpha(black, 0.08);
    }
    .panel-frame.focused {
      border-color: var(--accent-bg-color);
      box-shadow: 0 0 0 1px var(--accent-bg-color), 0 2px 6px alpha(black, 0.12);
    }
    .panel-frame.sibling-unfocused .panel-header .panel-title { opacity: 0.6; }
    .panel-frame:not(.focused) { border-color: alpha(white, 0.06); }
    .panel-frame.web { background-color: var(--view-bg-color); color: var(--view-fg-color); }
    .panel-header { padding: 3px 4px 3px 10px; min-height: 26px; border-bottom: 1px solid alpha(white, 0.06); }
    .panel-frame.web .panel-header { border-bottom-color: alpha(currentColor, 0.08); }
    .panel-header .panel-title { font-size: 0.85em; font-weight: 600; opacity: 0.85; }
    .panel-frame.focused .panel-header .panel-title { opacity: 1; }
    .panel-header .panel-subtitle { font-size: 0.78em; font-family: monospace; opacity: 0.5; }
    .panel-header button { min-height: 20px; min-width: 20px; padding: 2px; border-radius: 6px; color: inherit; }
    .panel-header .unread-dot { min-width: 7px; min-height: 7px; border-radius: 999px; background-color: var(--toastty-ready); }
    .zoom-banner {
      font-size: 0.8em; font-weight: 700; padding: 2px 10px; border-radius: 999px;
      background-color: var(--accent-bg-color); color: var(--accent-fg-color);
    }

    .terminal-placeholder { font-family: monospace; font-size: 11pt; padding: 10px 12px; }
    .terminal-placeholder .prompt { color: #7ec2b2; }
    .terminal-placeholder .cursor { background-color: var(--toastty-terminal-fg); min-width: 8px; min-height: 16px; }
    .terminal-placeholder .note { opacity: 0.45; font-size: 0.85em; }

    /* Right panel */
    .right-panel { background-color: var(--sidebar-bg-color); }

    /* Command palette */
    .command-palette { padding: 0; }
    .command-palette entry.palette-search { min-height: 40px; font-size: 1.1em; border-radius: 10px; margin: 10px; }
    .command-palette list { background: transparent; }
    .command-palette list > row { border-radius: 8px; margin: 1px 8px; padding: 7px 10px; }
    .command-palette list > row:selected { background-color: color-mix(in srgb, var(--accent-bg-color) 22%, transparent); color: inherit; }
    .command-palette .palette-subtitle { font-size: 0.82em; opacity: 0.6; }
    .command-palette .palette-footer { font-size: 0.8em; opacity: 0.55; padding: 6px 14px 10px 14px; }

    /* Empty state */
    .toastty-empty-state .shortcut-hint { font-size: 0.85em; }
    """
}
