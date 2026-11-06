import CGtk
import CoreState
import Foundation
import GhosttyKit

/// Receives the Ghostty actions Toastty claims (see `GhosttyRuntime.handle`).
@MainActor
protocol GhosttyRuntimeActionHandling: AnyObject {
    /// Return true to claim the action; false lets the widget's default
    /// handling run (render, cursor, title/pwd/bell/... signals).
    func handleGhosttyAction(_ action: ghostty_action_s, surface: ghostty_surface_t?) -> Bool
}

/// Unfocused-split dimming, read from Ghostty config like macOS
/// (`GhosttyRuntimeManager.resolveUnfocusedSplitStyle`).
struct GhosttyHostStyle: Equatable {
    var unfocusedOverlayOpacity: Double = 0.3
    var unfocusedFill: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)
    var background: (r: UInt8, g: UInt8, b: UInt8)?
    var foreground: (r: UInt8, g: UInt8, b: UInt8)?

    static func == (lhs: GhosttyHostStyle, rhs: GhosttyHostStyle) -> Bool {
        lhs.unfocusedOverlayOpacity == rhs.unfocusedOverlayOpacity
            && lhs.unfocusedFill == rhs.unfocusedFill
            && lhs.background.map { [$0.r, $0.g, $0.b] } == rhs.background.map { [$0.r, $0.g, $0.b] }
            && lhs.foreground.map { [$0.r, $0.g, $0.b] } == rhs.foreground.map { [$0.r, $0.g, $0.b] }
    }
}

/// The process's one Ghostty app: config loading (macOS
/// `GhosttyRuntimeManager` rules), color scheme, app focus, and action
/// dispatch. Everything runs on the GTK main thread.
@MainActor
final class GhosttyRuntime {
    enum ConfigSource: String { case envPath = "env_path", userPath = "user_path", defaultFiles = "default_files" }

    static let configPathEnvironmentKey = "TOASTTY_GHOSTTY_CONFIG_PATH"
    static let parseCLIArgsEnvironmentKey = "TOASTTY_GHOSTTY_PARSE_CLI_ARGS"

    private static var sharedInstance: GhosttyRuntime?
    private static var initializationFailed = false

    /// The shared runtime, created on first use. `nil` if libghostty cannot
    /// initialize (the host then falls back to placeholders).
    static var shared: GhosttyRuntime? {
        if let sharedInstance { return sharedInstance }
        guard initializationFailed == false else { return nil }
        let runtime = GhosttyRuntime()
        guard runtime.app != nil else {
            initializationFailed = true
            return nil
        }
        sharedInstance = runtime
        return runtime
    }

    /// Stops every terminal's renderer and IO threads once the main loop
    /// has quit. Terminal hosts keep their widgets (and surfaces) alive
    /// after the windows are destroyed, and a renderer thread still drawing
    /// when `exit()` tears down the GL driver crashes.
    static func shutdown() {
        guard sharedInstance != nil else { return }
        toastty_ghostty_free_all_surfaces()
    }

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private(set) var configSource: ConfigSource = .defaultFiles
    private(set) var configuredFontPoints: Double?
    private(set) var hostStyle = GhosttyHostStyle()
    private(set) var diagnostics: [String] = []
    weak var actionHandler: (any GhosttyRuntimeActionHandling)?
    /// Called after a config (re)load with the new configured font size.
    var onConfigurationChanged: (() -> Void)?
    private var colorSchemeHandler: gulong = 0
    private var hostStyleProvider: OpaquePointer?

    private init() {
        guard toastty_ghostty_init(CommandLine.argc, CommandLine.unsafeArgv) != 0 else {
            log("libghostty initialization failed")
            return
        }
        guard let config = Self.makeConfig(source: &configSource, diagnostics: &diagnostics) else {
            log("Ghostty config allocation failed")
            return
        }
        self.config = config
        configuredFontPoints = Self.configuredFontPoints(config)
        hostStyle = Self.hostStyle(config)

        var options = ToasttyGhosttyRuntimeOptions()
        options.supports_program_status = 1
        options.action_func = { app, target, action, _ in
            MainActor.assumeIsolated {
                GhosttyRuntime.sharedInstance?.dispatch(target: target, action: action) ?? false
            } ? 1 : 0
        }
        app = toastty_ghostty_app_new(config, &options)
        guard app != nil else {
            log("Ghostty app creation failed")
            return
        }
        followColorScheme()
        installHostStyle()
        log("Ghostty runtime ready (config: \(configSource.rawValue), font: \(configuredFontPoints.map { String($0) } ?? "default"), resources: \(toastty_ghostty_resources_dir().map { String(cString: $0) } ?? "none"))")
    }

    // MARK: Config

    private static func makeConfig(source: inout ConfigSource, diagnostics: inout [String]) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        source = loadConfig(config)
        withDebugLoginShellOverride { ghostty_config_finalize(config) }
        let count = ghostty_config_diagnostics_count(config)
        diagnostics = (0..<count).compactMap { index in
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            return diagnostic.message.map { String(cString: $0) }
        }
        for message in diagnostics {
            FileHandle.standardError.write(Data("toastty-linux: ghostty config: \(message)\n".utf8))
        }
        return config
    }

    /// Same precedence as macOS: CLI args (opt-in), `TOASTTY_GHOSTTY_CONFIG_PATH`,
    /// the user's Ghostty config, then Ghostty's default search paths.
    private static func loadConfig(_ config: ghostty_config_t) -> ConfigSource {
        let environment = ProcessInfo.processInfo.environment
        if truthy(environment[parseCLIArgsEnvironmentKey]) {
            ghostty_config_load_cli_args(config)
        }
        if let raw = environment[configPathEnvironmentKey] {
            if let path = normalizedConfigPath(raw), isRegularFile(path) {
                ghostty_config_load_file(config, path)
                ghostty_config_load_recursive_files(config)
                return .envPath
            }
            FileHandle.standardError.write(Data("toastty-linux: \(configPathEnvironmentKey)=\(raw) is not a readable absolute path; falling back\n".utf8))
        }
        var candidates: [String] = []
        if let xdg = normalizedConfigPath(environment["XDG_CONFIG_HOME"]) {
            candidates.append("\(xdg)/ghostty/config")
            candidates.append("\(xdg)/ghostty/config.ghostty")
        }
        candidates.append("\(NSHomeDirectory())/.config/ghostty/config")
        candidates.append("\(NSHomeDirectory())/.config/ghostty/config.ghostty")
        if let path = candidates.first(where: isRegularFile) {
            ghostty_config_load_file(config, path)
            ghostty_config_load_recursive_files(config)
            return .userPath
        }
        ghostty_config_load_default_files(config)
        return .defaultFiles
    }

    private static func withDebugLoginShellOverride(_ body: () -> Void) {
        guard let plan = GhosttyDebugLoginShellOverride.plan(environment: ProcessInfo.processInfo.environment) else {
            body()
            return
        }
        let originalShell = getenv("SHELL").map { String(cString: $0) }
        let originalTermProgram = getenv(GhosttyDebugLoginShellOverride.termProgramKey).map { String(cString: $0) }
        setenv("SHELL", plan.shellPath, 1)
        if plan.requiresTermProgramShim {
            setenv(GhosttyDebugLoginShellOverride.termProgramKey, GhosttyDebugLoginShellOverride.shimmedTermProgramValue, 1)
        }
        body()
        if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
        if plan.requiresTermProgramShim {
            if let originalTermProgram {
                setenv(GhosttyDebugLoginShellOverride.termProgramKey, originalTermProgram, 1)
            } else {
                unsetenv(GhosttyDebugLoginShellOverride.termProgramKey)
            }
        }
    }

    private static func configuredFontPoints(_ config: ghostty_config_t) -> Double? {
        var points = Float(AppState.defaultTerminalFontPoints)
        let key = "font-size"
        guard ghostty_config_get(config, &points, key, UInt(key.utf8.count)) else { return nil }
        return AppState.clampedTerminalFontPoints(Double(points))
    }

    private static func color(_ config: ghostty_config_t, _ key: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return nil }
        return (color.r, color.g, color.b)
    }

    private static func hostStyle(_ config: ghostty_config_t) -> GhosttyHostStyle {
        var style = GhosttyHostStyle()
        var opacity = 0.7
        let key = "unfocused-split-opacity"
        if ghostty_config_get(config, &opacity, key, UInt(key.utf8.count)) == false { opacity = 0.7 }
        style.unfocusedOverlayOpacity = min(max(1 - opacity, 0), 1)
        style.background = color(config, "background")
        style.foreground = color(config, "foreground")
        style.unfocusedFill = color(config, "unfocused-split-fill") ?? style.background ?? (0, 0, 0)
        return style
    }

    /// Re-reads the Ghostty config (`reload_config`, Toastty's Reload
    /// Configuration). Existing surfaces pick it up through
    /// `ghostty_app_update_config`.
    @discardableResult
    func reloadConfiguration() -> Bool {
        guard let app else { return false }
        var source = ConfigSource.defaultFiles
        var newDiagnostics: [String] = []
        guard let newConfig = Self.makeConfig(source: &source, diagnostics: &newDiagnostics) else { return false }
        ghostty_app_update_config(app, newConfig)
        if let config { ghostty_config_free(config) }
        config = newConfig
        configSource = source
        diagnostics = newDiagnostics
        configuredFontPoints = Self.configuredFontPoints(newConfig)
        hostStyle = Self.hostStyle(newConfig)
        installHostStyle()
        toastty_ghostty_app_schedule_tick(app)
        onConfigurationChanged?()
        return true
    }

    // MARK: Host chrome from Ghostty colors

    /// Panel frames use the terminal background/foreground (macOS reads the
    /// Ghostty background for the panel chrome); the unfocused-split overlay
    /// uses `unfocused-split-fill`/`-opacity`.
    private func installHostStyle() {
        guard let display = gdk_display_get_default() else { return }
        func hex(_ c: (r: UInt8, g: UInt8, b: UInt8)) -> String { String(format: "#%02x%02x%02x", c.r, c.g, c.b) }
        var css = ":root {"
        if let background = hostStyle.background { css += " --toastty-terminal-bg: \(hex(background));" }
        if let foreground = hostStyle.foreground { css += " --toastty-terminal-fg: \(hex(foreground));" }
        css += " }\n"
        let fill = hostStyle.unfocusedFill
        css += ".toastty-terminal-unfocused-overlay { background-color: rgba(\(fill.r), \(fill.g), \(fill.b), \(String(format: "%.3f", hostStyle.unfocusedOverlayOpacity))); }\n"
        css += TerminalChromeCSS.css
        if let hostStyleProvider {
            gtk_style_context_remove_provider_for_display(display, hostStyleProvider)
            g_object_unref(UnsafeMutableRawPointer(hostStyleProvider))
        }
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(display, OpaquePointer(provider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION) + 1)
        hostStyleProvider = OpaquePointer(provider)
    }

    // MARK: Color scheme and focus

    /// Ghostty's `theme = light:…,dark:…` follows the libadwaita scheme.
    private func followColorScheme() {
        let manager = adw_style_manager_get_default()!
        applyColorScheme()
        colorSchemeHandler = Signal.notify(manager, "dark") { [weak self] in self?.applyColorScheme() }
    }

    private func applyColorScheme() {
        guard let app else { return }
        let dark = adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    private var appFocused: Bool?

    func setAppFocus(_ focused: Bool) {
        guard let app, appFocused != focused else { return }
        appFocused = focused
        ghostty_app_set_focus(app, focused)
    }

    // MARK: Actions

    private func dispatch(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let surface: ghostty_surface_t? = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
        return actionHandler?.handleGhosttyAction(action, surface: surface) ?? false
    }

    // MARK: Helpers

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("toastty-linux: \(message)\n".utf8))
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(value)
    }

    private static func normalizedConfigPath(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false else { return nil }
        if raw.hasPrefix("~/") { return NSHomeDirectory() + raw.dropFirst(1) }
        return raw.hasPrefix("/") ? raw : nil
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue == false
    }
}

/// CSS for the terminal container (search bar, overlay, drop highlight).
enum TerminalChromeCSS {
    static let css = """
    .toastty-terminal { background-color: var(--toastty-terminal-bg); }
    .toastty-terminal-unfocused-overlay { border-radius: 0; }
    .toastty-terminal.drop-target { box-shadow: inset 0 0 0 2px var(--accent-bg-color); }
    .terminal-search-bar {
      margin: 6px 8px; padding: 3px; border-radius: 10px;
      background-color: var(--popover-bg-color); color: var(--popover-fg-color);
      box-shadow: 0 1px 4px alpha(black, 0.3);
    }
    .terminal-search-bar entry { min-height: 26px; min-width: 200px; }
    .terminal-search-bar .match-count { font-size: 0.8em; font-feature-settings: "tnum"; opacity: 0.7; margin: 0 4px; }
    .terminal-search-bar button { min-height: 24px; min-width: 24px; padding: 2px; }
    .terminal-link-hover {
      margin: 6px; padding: 2px 8px; border-radius: 6px; font-size: 0.8em; font-family: monospace;
      background-color: var(--popover-bg-color); color: var(--popover-fg-color); opacity: 0.92;
    }
    .terminal-exited-banner {
      margin: 8px; padding: 4px 10px; border-radius: 8px; font-size: 0.85em;
      background-color: color-mix(in srgb, var(--toastty-error) 85%, transparent); color: white;
    }
    """
}
