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

    /// The preference whose scheme the style manager currently forces.
    public static var appliedPreference: LinuxColorSchemePreference {
        let scheme = adw_style_manager_get_color_scheme(adw_style_manager_get_default())
        return LinuxColorSchemePreference.allCases.first { $0.adwScheme == scheme } ?? .system
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
    /* toastty_clock_spinner (CGtkShim): Adwaita hides a spinner that is not
       :checked; this one draws its own turn. Placed first so the per-context
       sizes below win. */
    spinner.clock-spinner { opacity: 1; min-width: 16px; min-height: 16px; }
    :root {
      --toastty-working: #e8a635;
      --toastty-approval: #e8a635;
      --toastty-ready: #4fa58a;
      --toastty-error: #e55c5c;
      --toastty-idle: #a8977f;
      --toastty-waiting: #c1aa8a;
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
    .session-row .session-summary.waiting { color: var(--toastty-waiting); opacity: 1; }

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
    .status-chip.waiting { color: var(--toastty-waiting); background-color: color-mix(in srgb, var(--toastty-waiting) 14%, transparent); }

    .later-flag { color: var(--toastty-later); }

    .count-badge {
      font-size: 0.75em; font-weight: 700; min-width: 16px; min-height: 16px; padding: 0 5px;
      border-radius: 999px; background-color: var(--accent-bg-color); color: var(--accent-fg-color);
    }
    .count-badge.quiet { background-color: alpha(currentColor, 0.12); color: inherit; }
    /* macOS workspaceAgentCountBadge: muted text, working tint while active. */
    .agent-count-badge {
      font-size: 0.75em; font-weight: 600; min-height: 16px; padding: 0 7px;
      border-radius: 999px; background-color: alpha(currentColor, 0.1); color: alpha(currentColor, 0.65);
    }
    .agent-count-badge.active { background-color: color-mix(in srgb, var(--toastty-working) 15%, transparent); }
    .agent-count-badge spinner { min-width: 8px; min-height: 8px; }

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
    .workspace-task-control { margin-start: 12px; }
    .workspace-task-control popover button { min-height: 28px; padding: 2px 8px; }
    .workspace-task-control .workspace-task-done { color: var(--toastty-done); }
    .workspace-task-status { font-size: 0.9em; margin-end: 2px; }
    .workspace-task-status-dot { min-width: 8px; min-height: 8px; border-radius: 999px; background-color: var(--toastty-working); }
    .workspace-task-separator { margin: 8px 2px 8px 4px; }

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

    /* Task marks (macOS TaskStageMark) */
    :root {
      --toastty-review: #6e9fe6;
      --toastty-question: #e8a635;
      --toastty-to-ship: #b98ce0;
      --toastty-done: #7cc47f;
      --toastty-quiet: #8a8279;
    }
    .task-mark { min-width: 10px; min-height: 10px; border-radius: 2px; font-size: 7pt; font-weight: 900; }
    .task-mark.starting { min-width: 8px; min-height: 8px; border: 1px dashed var(--toastty-quiet); border-radius: 2px; }
    .task-mark.setup-problem { min-width: 8px; min-height: 8px; border: 1px dashed var(--toastty-approval); border-radius: 2px; }
    .task-mark.review { background-color: color-mix(in srgb, var(--toastty-review) 22%, transparent); }
    .task-mark.review .task-mark-dot { min-width: 5px; min-height: 5px; border-radius: 999px; background-color: var(--toastty-review); }
    .task-mark.question { color: var(--toastty-question); background-color: color-mix(in srgb, var(--toastty-question) 22%, transparent); }
    .task-mark.error { min-width: 7px; min-height: 7px; background-color: var(--toastty-error); }
    .task-mark.ready { min-width: 7px; min-height: 7px; background-color: var(--toastty-ready); }
    .task-mark.needs-input { min-width: 7px; min-height: 7px; background-color: var(--toastty-approval);
      box-shadow: 0 0 0 3px color-mix(in srgb, var(--toastty-approval) 22%, transparent); }
    .task-mark.quiet { min-width: 6px; min-height: 6px; border: 1.2px solid var(--toastty-quiet); border-radius: 2px; }
    .task-mark.to-ship { color: var(--toastty-to-ship); background-color: color-mix(in srgb, var(--toastty-to-ship) 22%, transparent); }
    .task-mark.done { color: var(--toastty-done); background-color: color-mix(in srgb, var(--toastty-done) 20%, transparent); }
    .task-mark.archived { color: var(--toastty-quiet); background-color: alpha(currentColor, 0.1); }
    .task-mark-icon.waiting { color: var(--toastty-quiet); }
    .task-mark-slot spinner { min-width: 9px; min-height: 9px; -gtk-icon-size: 9px; }
    .task-release-mark { color: var(--toastty-to-ship); font-size: 0.75em; }
    .task-tag {
      font-size: 0.78em; padding: 0 5px; border-radius: 4px;
      background-color: alpha(currentColor, 0.08); opacity: 0.85;
    }
    .task-pr-tag {
      font-size: 0.78em; font-family: monospace; font-weight: 600; padding: 0 5px; border-radius: 4px;
      color: var(--toastty-done); border: 1px solid color-mix(in srgb, var(--toastty-done) 45%, transparent);
    }
    .task-branch { font-size: 0.78em; font-family: monospace; opacity: 0.7; }

    /* Tasks view (macOS TasksView) */
    .tasks-view { background-color: var(--view-bg-color); }
    .tasks-header { padding: 14px 18px 10px 18px; }
    .tasks-title { font-size: 1.15em; font-weight: 700; }
    .tasks-new-key {
      font-size: 0.75em; font-weight: 600; padding: 0 4px; border-radius: 3px;
      border: 1px solid alpha(currentColor, 0.45);
    }
    .tasks-banners { padding: 0 18px 8px 18px; }
    .tasks-banner { padding: 8px 10px; border-radius: 8px; font-size: 0.9em; }
    .tasks-banner.webhook, .tasks-banner.config-error {
      background-color: color-mix(in srgb, var(--toastty-approval) 16%, transparent);
      border-left: 3px solid var(--toastty-approval);
    }
    .tasks-list { padding-bottom: 16px; }
    .tasks-group { padding: 14px 18px 6px 18px; font-size: 0.8em; font-weight: 700; opacity: 0.6; }
    .tasks-group.hot { color: var(--toastty-question); opacity: 1; }
    .tasks-group.review { color: var(--toastty-review); opacity: 1; }
    .tasks-group-count { font-family: monospace; opacity: 0.7; }
    .tasks-group-toggle { padding: 0; border-radius: 0; }
    .tasks-group-toggle .tasks-group { padding-left: 18px; }
    .tasks-lane { padding: 6px 18px; font-size: 0.9em; font-weight: 600; color: var(--toastty-to-ship); }
    .tasks-row { padding: 9px 18px; border-top: 1px solid alpha(currentColor, 0.06); }
    .tasks-row:hover { background-color: alpha(currentColor, 0.04); }
    .tasks-row.selected { background-color: alpha(currentColor, 0.08); box-shadow: inset 2px 0 var(--accent-bg-color); }
    .tasks-row.child { padding-left: 36px; }
    .tasks-row.context { opacity: 0.65; }
    .tasks-child-arrow { opacity: 0.55; font-size: 0.85em; }
    .tasks-row-title { font-weight: 500; }
    .tasks-row-title.unread { font-weight: 700; }
    .tasks-row-status { font-size: 0.86em; opacity: 0.6; }
    .tasks-row-age { font-size: 0.86em; opacity: 0.5; }
    .tasks-detail { padding: 18px 18px 16px 18px; }
    .tasks-detail-origin { font-size: 0.86em; opacity: 0.55; }
    .tasks-detail-title { font-size: 1.15em; font-weight: 700; }
    .tasks-detail-text { font-size: 0.92em; opacity: 0.8; }
    .tasks-detail-error { font-size: 0.86em; color: var(--toastty-error); }
    .tasks-card { border-radius: 8px; background-color: alpha(currentColor, 0.04); border: 1px solid alpha(currentColor, 0.1); }
    .tasks-card-title { font-size: 0.75em; font-weight: 700; opacity: 0.55; padding: 8px 12px; }
    .tasks-card-body { padding: 12px; }
    .tasks-key { font-size: 0.92em; opacity: 0.55; }
    .tasks-value { font-size: 0.92em; }
    .tasks-why { font-size: 0.84em; opacity: 0.55; }
    /* The workspace page (Tasks/WorkspaceOverviewPage.swift). */
    .workspace-overview-subtitle { font-size: 0.86em; opacity: 0.6; }
    .workspace-overview-main { padding: 4px 18px 18px 18px; }
    .workspace-overview-card .tasks-card-body { padding: 10px 12px 12px 12px; }
    .workspace-overview-synopsis { font-size: 1.02em; line-height: 1.4; }
    .workspace-overview-outcome { font-size: 0.86em; opacity: 0.75; }
    .workspace-overview-recent { padding: 6px 4px; border-radius: 6px; }
    .workspace-overview-recent:hover, .workspace-overview .tasks-card .tasks-row:hover { background-color: alpha(currentColor, 0.05); }
    .workspace-overview-pads { background-color: var(--sidebar-bg-color); }
    .workspace-overview-pads-header { padding: 10px 12px 2px 6px; }
    .workspace-overview-pads-empty { padding: 4px 14px 10px 14px; }
    .workspace-overview-preview-header { padding: 6px 8px 6px 14px; }
    button.kept { color: var(--accent-color); }
    .tasks-history-line { font-size: 0.92em; opacity: 0.8; }
    .tasks-action { font-size: 0.92em; }
    .tasks-empty { opacity: 0.6; }
    .task-setup-text { font-size: 0.95em; opacity: 0.85; }
    .task-setup-note { font-size: 0.88em; opacity: 0.65; padding-left: 10px; border-left: 2px solid alpha(currentColor, 0.2); }
    .task-setup-note.problem { opacity: 0.85; border-left-color: color-mix(in srgb, var(--toastty-error) 55%, transparent); }
    .task-setup-workspace { padding: 12px 16px; border-radius: 10px; border: 1px solid alpha(currentColor, 0.1); }
    .webhook-agent-warning { padding: 8px; border-radius: 6px; background-color: color-mix(in srgb, var(--toastty-approval) 15%, transparent); }
    .webhook-hint { padding: 6px 8px; border-radius: 4px; background-color: alpha(currentColor, 0.06); }

    /* Coordinator chat (macOS CoordinatorChatView, ToasttyTranscriptView) */
    .coordinator-chat { background-color: var(--view-bg-color); color: var(--view-fg-color); }
    .transcript-list { padding: 14px 18px 18px 18px; }
    .transcript-banner { padding: 6px 12px; font-size: 0.86em; opacity: 0.7; }
    .transcript-older { font-size: 0.86em; }
    .transcript-new-label { color: #e8643a; font-size: 0.78em; font-weight: 800; }
    .transcript-new separator { background-color: color-mix(in srgb, #e8643a 60%, transparent); }
    .transcript-disclosure { padding: 2px 6px; min-height: 0; }
    .transcript-disclosure-text { font-size: 0.86em; opacity: 0.6; }
    .transcript-strip {
      padding: 7px 11px; border-radius: 8px; font-family: monospace; font-size: 0.8em;
      background-color: alpha(currentColor, 0.04); border: 1px solid alpha(currentColor, 0.1); opacity: 0.8;
    }
    .transcript-strip-button { padding: 0; min-height: 0; border-radius: 8px; }
    .transcript-strip spinner, .transcript-working spinner, .transcript-disclosure spinner { min-width: 10px; min-height: 10px; }
    .transcript-work { padding-left: 14px; border-left: 2px solid alpha(currentColor, 0.12); }
    .transcript-working { font-family: monospace; font-size: 0.8em; opacity: 0.65; padding: 4px 0; }
    .transcript-user { margin-left: 48px; }
    .transcript-bubble {
      padding: 8px 12px; border-radius: 14px;
      background-color: color-mix(in srgb, var(--accent-bg-color) 16%, transparent);
    }
    .transcript-queued .transcript-bubble, .transcript-user.pending .transcript-bubble { background-color: alpha(currentColor, 0.06); }
    .transcript-quote { font-size: 0.82em; opacity: 0.65; padding: 0; min-height: 0; }
    .transcript-caption { font-size: 0.78em; opacity: 0.55; }
    .transcript-receipt { font-size: 0.82em; color: var(--toastty-approval); }
    .transcript-hover-action { min-width: 22px; min-height: 22px; padding: 0; opacity: 0.45; }
    .transcript-hover-action:hover { opacity: 1; }
    .transcript-link-button { font-size: 0.82em; padding: 0 4px; min-height: 0; color: var(--accent-color); }
    .transcript-assistant.commentary { opacity: 0.7; }
    .transcript-host-text { font-size: 0.92em; opacity: 0.85; }
    .transcript-sender { padding: 10px 12px; border-radius: 10px; border: 1px solid alpha(currentColor, 0.12); }
    .transcript-sender-name { font-weight: 700; font-size: 0.9em; }
    .transcript-muted { font-size: 0.82em; opacity: 0.5; }
    .transcript-tools { padding: 2px 0; }
    .transcript-tool { font-family: monospace; font-size: 0.8em; padding: 1px 0; }
    .transcript-tool-button { padding: 0 4px; min-height: 0; }
    .transcript-tool-mark.ok { color: var(--toastty-ready); }
    .transcript-tool-mark.failed { color: var(--toastty-error); }
    .transcript-tool-name { font-weight: 700; }
    .transcript-tool-detail { opacity: 0.6; }
    .transcript-tool-details { font-family: monospace; font-size: 0.78em; opacity: 0.75; padding: 6px 8px; border-radius: 6px; background-color: alpha(currentColor, 0.05); }
    .transcript-jump { box-shadow: 0 2px 8px alpha(black, 0.2); }
    .markdown .md-heading { font-weight: 800; }
    .markdown .md-h1 { font-size: 1.3em; }
    .markdown .md-h2 { font-size: 1.15em; }
    .markdown .md-h3 { font-size: 1.05em; }
    .markdown .md-quote { padding-left: 10px; border-left: 3px solid alpha(currentColor, 0.2); opacity: 0.85; }
    .markdown .md-list-marker { opacity: 0.6; }
    .markdown .md-code { padding: 8px 10px; border-radius: 8px; background-color: alpha(currentColor, 0.06); }
    .markdown .md-code-text { font-family: monospace; font-size: 0.88em; }
    .markdown .md-code-language { font-size: 0.72em; opacity: 0.5; }
    .markdown .md-table-header { font-weight: 700; }
    .interaction-card { padding: 12px; border-radius: 10px; border: 1px solid color-mix(in srgb, var(--toastty-approval) 45%, transparent);
      background-color: color-mix(in srgb, var(--toastty-approval) 8%, transparent); }
    .interaction-kind { font-size: 0.72em; font-weight: 800; color: var(--toastty-approval); }
    .interaction-question-header { font-size: 0.78em; font-weight: 700; opacity: 0.6; }
    .interaction-status { font-size: 0.84em; opacity: 0.7; }
    .coordinator-intro { padding: 24px; }
    .coordinator-notice { padding: 8px 14px; font-size: 0.88em;
      background-color: color-mix(in srgb, var(--toastty-approval) 14%, transparent);
      border-top: 1px solid color-mix(in srgb, var(--toastty-approval) 35%, transparent); }
    .coordinator-notice-button { font-weight: 700; color: var(--toastty-approval); padding: 2px 6px; min-height: 0; }
    .composer { padding: 8px 12px 12px 12px; border-top: 1px solid alpha(currentColor, 0.08); }
    .composer-field { border-radius: 12px; border: 1px solid alpha(currentColor, 0.15); background-color: var(--view-bg-color); }
    .composer-field:focus-within { border-color: var(--accent-bg-color); }
    .composer-text, .composer-text text { background: transparent; }
    .composer-placeholder { opacity: 0.45; }
    .composer-reply { padding: 4px 8px; border-radius: 8px; background-color: alpha(currentColor, 0.05); font-size: 0.86em; }
    .composer-delivery { font-size: 0.86em; font-weight: 700; }
    .composer-delivery.queue { color: var(--accent-color); }
    .mention-popover list, .mention-list { padding: 4px; }
    .mention-section { font-size: 0.72em; font-weight: 800; opacity: 0.5; padding: 6px 8px 2px 8px; }
    .mention-row { padding: 4px 8px; min-height: 0; }
    .mention-row.selected { background-color: color-mix(in srgb, var(--accent-bg-color) 22%, transparent); }
    .mention-detail { font-size: 0.82em; }

    /* Coordinator dock and panel */
    .coordinator-dock { background-color: var(--view-bg-color); border-right: 1px solid alpha(currentColor, 0.1); }
    .coordinator-dock-header { padding: 8px 8px 8px 12px; border-bottom: 1px solid alpha(currentColor, 0.08); }
    .coordinator-dock-title { font-weight: 700; }
    .coordinator-dock-status { font-size: 0.8em; opacity: 0.6; }
    .coordinator-panel-button { font-size: 0.8em; font-weight: 600; min-height: 20px; padding: 1px 8px; }

    /* Quick entry (macOS QuickEntryView) */
    .quick-entry { padding: 14px 16px 14px 16px; }
    .quick-entry-dot { min-width: 6px; min-height: 6px; border-radius: 999px; background-color: var(--accent-bg-color); }
    .quick-entry-title { font-size: 0.8em; font-weight: 600; opacity: 0.6; }
    .quick-entry-hint { font-size: 0.8em; font-weight: 600; color: var(--accent-color); }
    .quick-entry-field { border-radius: 10px; border: 1px solid alpha(currentColor, 0.15); }
    .quick-entry-field:focus-within { border-color: var(--accent-bg-color); }
    .quick-entry-text, .quick-entry-text text { background: transparent; font-size: 1.05em; }
    .quick-entry-placeholder { opacity: 0.45; font-size: 1.05em; }
    .quick-entry-attach { font-size: 0.86em; }
    .quick-entry-error { color: var(--toastty-error); font-size: 0.86em; }
    .quick-entry-pill { font-size: 0.86em; border-radius: 999px; padding: 2px 10px; }
    .quick-entry-pill.missing { box-shadow: inset 0 0 0 1px var(--toastty-approval); }
    .quick-entry-pill.open { background-color: color-mix(in srgb, var(--accent-bg-color) 22%, transparent); }
    .quick-entry-key { font-size: 0.8em; font-family: monospace; opacity: 0.7; }
    .quick-entry-picker .quick-entry-section { font-size: 0.72em; font-weight: 800; opacity: 0.5; padding: 6px 6px 2px 6px; }
    .quick-entry-row { padding: 4px 8px; min-height: 0; }
    .quick-entry-row.selected { background-color: color-mix(in srgb, var(--accent-bg-color) 22%, transparent); }
    .quick-entry-row.muted { opacity: 0.55; }
    .quick-entry-number { font-family: monospace; opacity: 0.55; }
    .quick-entry-warning { font-size: 0.8em; color: var(--toastty-approval); }
    .quick-entry-column.focused .quick-entry-section { color: var(--accent-color); opacity: 1; }

    /* Sidebar with tasks (macOS SidebarTasksHeader, bucketed cards) */
    .sidebar-tasks-header { padding: 4px 8px 8px 8px; }
    .sidebar-coordinator, .sidebar-tasks-row { padding: 5px 8px; border-radius: 8px; }
    .sidebar-coordinator:hover, .sidebar-tasks-row:hover { background-color: alpha(currentColor, 0.06); }
    .sidebar-coordinator.selected { background-color: color-mix(in srgb, var(--accent-bg-color) 16%, transparent); }
    .sidebar-tasks-open { padding: 0; min-height: 0; }
    .sidebar-coordinator-title, .sidebar-tasks-title { font-weight: 700; }
    .sidebar-coordinator-status { font-size: 0.78em; opacity: 0.6; }
    .sidebar-coordinator-status.working { color: var(--toastty-working); opacity: 1; }
    .sidebar-coordinator-status.unread { color: var(--toastty-ready); opacity: 1; }
    .sidebar-coordinator-status.approval { color: var(--toastty-approval); opacity: 1; }
    .sidebar-coordinator-status.error { color: var(--toastty-error); opacity: 1; }
    .sidebar-webhook-pill { font-size: 0.72em; font-weight: 700; color: var(--toastty-approval); min-height: 0; padding: 0 6px;
      border: 1px solid var(--toastty-approval); border-radius: 999px; }
    .sidebar-segment { margin-top: 6px; }
    .sidebar-segment button { font-size: 0.86em; padding: 2px 6px; min-height: 0; }
    .sidebar-count { font-size: 0.72em; font-weight: 800; padding: 0 5px; border-radius: 999px; }
    .sidebar-count.needs-you { background-color: color-mix(in srgb, var(--toastty-approval) 30%, transparent); }
    .sidebar-count.review { background-color: color-mix(in srgb, var(--toastty-review) 30%, transparent); }
    .sidebar-task-cards { padding: 4px 6px 10px 6px; }
    .sidebar-chevron { min-width: 18px; min-height: 18px; padding: 0; }
    .sidebar-bucket { font-size: 0.68em; font-weight: 800; opacity: 0.55; padding: 6px 4px 2px 4px; }
    .sidebar-bucket.needs-you { color: var(--toastty-approval); opacity: 1; }
    .sidebar-bucket.review { color: var(--toastty-review); opacity: 1; }
    .sidebar-bucket-counts { font-size: 0.72em; }
    .sidebar-count-mark { min-width: 6px; min-height: 6px; border-radius: 999px; background-color: var(--toastty-idle); }
    .sidebar-count-mark.needs-you { background-color: var(--toastty-approval); }
    .sidebar-count-mark.review { background-color: var(--toastty-review); border-radius: 1px; }
    .sidebar-count-number { opacity: 0.7; }
    .session-row.child { margin-left: 14px; }
    .session-row.context { opacity: 0.6; }
    .sidebar-finished { padding-top: 4px; }
    .sidebar-to-ship { font-size: 0.78em; font-weight: 700; color: var(--toastty-to-ship); padding: 0 4px; min-height: 0; }
    .sidebar-done, .sidebar-more { font-size: 0.78em; padding: 0 4px; min-height: 0; opacity: 0.7; }
    .sidebar-nothing { padding: 18px; }
    .sidebar-folded { font-size: 0.78em; padding: 0 4px 0 18px; min-height: 0; opacity: 0.7; }

    /* Attachments */
    .attachment-chip { padding: 3px 6px; border-radius: 8px; background-color: alpha(currentColor, 0.07); }
    .attachment-thumbnail { border-radius: 4px; }
    .attachment-name { font-size: 0.86em; }
    .attachment-remove { min-width: 18px; min-height: 18px; padding: 0; }
    """
}
