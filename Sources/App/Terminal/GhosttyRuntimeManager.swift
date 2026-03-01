#if TOASTTY_HAS_GHOSTTY_KIT
import AppKit
import CoreState
import Foundation
import GhosttyKit

@MainActor
protocol GhosttyRuntimeActionHandling: AnyObject {
    func handleGhosttyRuntimeAction(_ action: GhosttyRuntimeAction) -> Bool
}

struct GhosttyRuntimeAction: Sendable {
    enum Intent: Sendable {
        case split(PaneSplitDirection)
        case focus(PaneFocusDirection)
        case resizeSplit(PaneResizeDirection, amount: Int)
        case equalizeSplits
        case toggleFocusedPanelMode
    }

    let surfaceHandle: UInt?
    let intent: Intent

    var logIntentName: String {
        switch intent {
        case .split(let direction):
            return "split.\(direction.rawValue)"
        case .focus(let direction):
            return "focus.\(direction.rawValue)"
        case .resizeSplit(let direction, _):
            return "resize_split.\(direction.rawValue)"
        case .equalizeSplits:
            return "equalize_splits"
        case .toggleFocusedPanelMode:
            return "toggle_focused_panel_mode"
        }
    }
}

private final class GhosttyActionCallbackResult: @unchecked Sendable {
    var handled = false
}

private func ghosttyTargetName(_ target: ghostty_target_s) -> String {
    switch target.tag {
    case GHOSTTY_TARGET_SURFACE:
        return "surface"
    case GHOSTTY_TARGET_APP:
        return "app"
    default:
        return "unknown(\(target.tag.rawValue))"
    }
}

private func ghosttyActionName(_ action: ghostty_action_s) -> String {
    switch action.tag {
    case GHOSTTY_ACTION_NEW_SPLIT:
        return "new_split"
    case GHOSTTY_ACTION_GOTO_SPLIT:
        return "goto_split"
    case GHOSTTY_ACTION_RESIZE_SPLIT:
        return "resize_split"
    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
        return "equalize_splits"
    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
        return "toggle_split_zoom"
    default:
        return "unknown(\(action.tag.rawValue))"
    }
}

private func makeGhosttyRuntimeAction(target: ghostty_target_s, action: ghostty_action_s) -> GhosttyRuntimeAction? {
    let surfaceHandle: UInt?
    switch target.tag {
    case GHOSTTY_TARGET_SURFACE:
        guard let surface = target.target.surface else {
            return nil
        }
        surfaceHandle = UInt(bitPattern: surface)

    case GHOSTTY_TARGET_APP:
        surfaceHandle = nil

    default:
        return nil
    }

    let intent: GhosttyRuntimeAction.Intent
    switch action.tag {
    case GHOSTTY_ACTION_NEW_SPLIT:
        guard let direction = PaneSplitDirection(ghosttyDirection: action.action.new_split) else {
            return nil
        }
        intent = .split(direction)

    case GHOSTTY_ACTION_GOTO_SPLIT:
        guard let direction = PaneFocusDirection(ghosttyDirection: action.action.goto_split) else {
            return nil
        }
        intent = .focus(direction)

    case GHOSTTY_ACTION_RESIZE_SPLIT:
        guard let direction = PaneResizeDirection(ghosttyDirection: action.action.resize_split.direction) else {
            return nil
        }
        intent = .resizeSplit(direction, amount: Int(action.action.resize_split.amount))

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
        intent = .equalizeSplits

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
        intent = .toggleFocusedPanelMode

    default:
        return nil
    }

    return GhosttyRuntimeAction(surfaceHandle: surfaceHandle, intent: intent)
}

private func ghosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    // Store as an integer handle to satisfy strict Sendable checks across dispatch hops.
    let managerHandle = UInt(bitPattern: userdata)
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: managerHandle) else { return }
        let manager = Unmanaged<GhosttyRuntimeManager>.fromOpaque(pointer).takeUnretainedValue()
        manager.scheduleImmediateTick()
    }
}

private func ghosttyActionCallback(app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
    guard let app else {
        ToasttyLog.warning("Ghostty callback missing app handle", category: .ghostty)
        return false
    }
    guard let userdata = ghostty_app_userdata(app) else {
        ToasttyLog.warning("Ghostty callback missing app userdata", category: .ghostty)
        return false
    }
    guard let runtimeAction = makeGhosttyRuntimeAction(target: target, action: action) else {
        ToasttyLog.debug(
            "Skipping Ghostty action without Toastty handler",
            category: .ghostty,
            metadata: [
                "target": ghosttyTargetName(target),
                "action": ghosttyActionName(action),
            ]
        )
        return false
    }

    // Keep callback semantics synchronous for Ghostty while safely hopping to main when needed.
    let managerHandle = UInt(bitPattern: userdata)
    if Thread.isMainThread {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: managerHandle) else {
            ToasttyLog.warning("Ghostty callback missing manager pointer", category: .ghostty)
            return false
        }
        let manager = Unmanaged<GhosttyRuntimeManager>.fromOpaque(pointer).takeUnretainedValue()
        let handled = MainActor.assumeIsolated {
            manager.routeRuntimeAction(runtimeAction)
        }
        ToasttyLog.debug(
            "Handled Ghostty runtime action",
            category: .ghostty,
            metadata: [
                "intent": runtimeAction.logIntentName,
                "target": ghosttyTargetName(target),
                "handled": handled ? "true" : "false",
                "thread": "main",
            ]
        )
        return handled
    }

    let result = GhosttyActionCallbackResult()
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: managerHandle) else {
            semaphore.signal()
            return
        }
        let manager = Unmanaged<GhosttyRuntimeManager>.fromOpaque(pointer).takeUnretainedValue()
        result.handled = manager.routeRuntimeAction(runtimeAction)
        semaphore.signal()
    }

    // Avoid deadlocking callback threads if the main queue is blocked behind runtime internals.
    guard semaphore.wait(timeout: .now() + .milliseconds(250)) == .success else {
        ToasttyLog.warning(
            "Ghostty action callback timed out waiting for main queue",
            category: .ghostty,
            metadata: [
                "intent": runtimeAction.logIntentName,
                "target": ghosttyTargetName(target),
                "thread": "background",
            ]
        )
        return false
    }
    ToasttyLog.debug(
        "Handled Ghostty runtime action",
        category: .ghostty,
        metadata: [
            "intent": runtimeAction.logIntentName,
            "target": ghosttyTargetName(target),
            "handled": result.handled ? "true" : "false",
            "thread": "background",
        ]
    )
    return result.handled
}

private extension PaneSplitDirection {
    init?(ghosttyDirection: ghostty_action_split_direction_e) {
        switch ghosttyDirection {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT:
            self = .right
        case GHOSTTY_SPLIT_DIRECTION_DOWN:
            self = .down
        case GHOSTTY_SPLIT_DIRECTION_LEFT:
            self = .left
        case GHOSTTY_SPLIT_DIRECTION_UP:
            self = .up
        default:
            return nil
        }
    }
}

private extension PaneFocusDirection {
    init?(ghosttyDirection: ghostty_action_goto_split_e) {
        switch ghosttyDirection {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS:
            self = .previous
        case GHOSTTY_GOTO_SPLIT_NEXT:
            self = .next
        case GHOSTTY_GOTO_SPLIT_UP:
            self = .up
        case GHOSTTY_GOTO_SPLIT_DOWN:
            self = .down
        case GHOSTTY_GOTO_SPLIT_LEFT:
            self = .left
        case GHOSTTY_GOTO_SPLIT_RIGHT:
            self = .right
        default:
            return nil
        }
    }
}

private extension PaneResizeDirection {
    init?(ghosttyDirection: ghostty_action_resize_split_direction_e) {
        switch ghosttyDirection {
        case GHOSTTY_RESIZE_SPLIT_UP:
            self = .up
        case GHOSTTY_RESIZE_SPLIT_DOWN:
            self = .down
        case GHOSTTY_RESIZE_SPLIT_LEFT:
            self = .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT:
            self = .right
        default:
            return nil
        }
    }
}

private func makeGhosttyRuntimeConfig(userdata: UnsafeMutableRawPointer) -> ghostty_runtime_config_s {
    ghostty_runtime_config_s(
        userdata: userdata,
        supports_selection_clipboard: false,
        wakeup_cb: { userdata in
            // Ghostty may invoke wakeup from a renderer thread; all app ticks must return to main.
            ghosttyWakeupCallback(userdata)
        },
        action_cb: { app, target, action in
            ghosttyActionCallback(app: app, target: target, action: action)
        },
        read_clipboard_cb: { _, _, _ in },
        confirm_read_clipboard_cb: { _, _, _, _ in },
        write_clipboard_cb: { _, _, _, _, _ in },
        close_surface_cb: { _, _ in }
    )
}

private enum GhosttyConfigSource: String {
    case envPath = "env_path"
    case userPath = "user_path"
    case defaultFiles = "default_files"
}

@MainActor
final class GhosttyRuntimeManager {
    static let shared = GhosttyRuntimeManager()

    private static let ghosttyConfigPathEnvironmentKey = "TOASTTY_GHOSTTY_CONFIG_PATH"
    private static let ghosttyParseCLIArgsEnvironmentKey = "TOASTTY_GHOSTTY_PARSE_CLI_ARGS"

    weak var actionHandler: (any GhosttyRuntimeActionHandling)?

    private var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private(set) var configuredTerminalFontPoints: Double?

    private init() {
        guard Self.initializeGhosttyRuntime() else {
            ToasttyLog.error("Ghostty initialization failed", category: .ghostty)
            return
        }

        guard let config = ghostty_config_new() else {
            ToasttyLog.error("Ghostty config allocation failed", category: .ghostty)
            return
        }
        self.config = config

        let configSource = Self.loadGhosttyConfig(config)
        Self.logGhosttyConfigDiagnostics(config, source: configSource)
        configuredTerminalFontPoints = Self.resolveConfiguredTerminalFontPoints(config)
        Self.applyHostStyle(config)
        ghostty_config_finalize(config)

        var runtimeConfig = makeGhosttyRuntimeConfig(
            userdata: Unmanaged.passUnretained(self).toOpaque()
        )

        app = ghostty_app_new(&runtimeConfig, config)
        if app == nil {
            ToasttyLog.error("Ghostty runtime creation failed", category: .ghostty)
        }
        scheduleImmediateTick()
    }

    func makeSurface(
        hostView: NSView,
        workingDirectory: String,
        fontPoints: Double
    ) -> ghostty_surface_t? {
        guard let app else { return nil }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(hostView).toOpaque()
        surfaceConfig.userdata = Unmanaged.passUnretained(hostView).toOpaque()
        let hostScale = hostView.window?.screen?.backingScaleFactor
            ?? hostView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        surfaceConfig.scale_factor = max(Double(hostScale), 1)
        surfaceConfig.font_size = Float(fontPoints)
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        let surface = workingDirectory.withCString { cwdPointer in
            surfaceConfig.working_directory = cwdPointer
            return ghostty_surface_new(app, &surfaceConfig)
        }
        scheduleImmediateTick()
        return surface
    }

    @discardableResult
    func reloadConfiguration() -> Bool {
        guard let app else {
            ToasttyLog.warning("Reload config requested before Ghostty app init", category: .ghostty)
            return false
        }
        guard let newConfig = ghostty_config_new() else {
            ToasttyLog.error("Ghostty config allocation failed during reload", category: .ghostty)
            return false
        }

        let configSource = Self.loadGhosttyConfig(newConfig)
        Self.logGhosttyConfigDiagnostics(newConfig, source: configSource)
        configuredTerminalFontPoints = Self.resolveConfiguredTerminalFontPoints(newConfig)
        Self.applyHostStyle(newConfig)
        ghostty_config_finalize(newConfig)

        // Ghostty's App.updateConfig docs state the caller retains ownership and
        // may free its config buffers immediately after this call returns.
        ghostty_app_update_config(app, newConfig)

        if let previousConfig = config {
            ghostty_config_free(previousConfig)
        }
        config = newConfig
        scheduleImmediateTick()

        ToasttyLog.info(
            "Reloaded Ghostty configuration",
            category: .ghostty,
            metadata: [
                "source": configSource.rawValue,
                "configured_font_points": configuredTerminalFontPoints.map { String(format: "%.2f", $0) } ?? "unset",
            ]
        )
        return true
    }

    private static func initializeGhosttyRuntime() -> Bool {
        ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
    }

    private static func loadGhosttyConfig(_ config: ghostty_config_t) -> GhosttyConfigSource {
        let environment = ProcessInfo.processInfo.environment
        if truthy(environment[ghosttyParseCLIArgsEnvironmentKey]) {
            ghostty_config_load_cli_args(config)
            ToasttyLog.info(
                "Ghostty CLI arg parsing enabled",
                category: .ghostty,
                metadata: [
                    "env_key": ghosttyParseCLIArgsEnvironmentKey,
                ]
            )
        }

        if let rawEnvPath = environment[ghosttyConfigPathEnvironmentKey] {
            guard let envPath = normalizedConfigPath(from: rawEnvPath) else {
                ToasttyLog.warning(
                    "Configured Ghostty config path is invalid; falling back",
                    category: .ghostty,
                    metadata: [
                        "path": rawEnvPath,
                        "reason": "must be absolute or use ~/ prefix",
                    ]
                )
                return loadFallbackGhosttyConfig(config, environment: environment)
            }

            if isRegularFile(at: envPath) {
                envPath.withCString { pathPointer in
                    ghostty_config_load_file(config, pathPointer)
                }
                ghostty_config_load_recursive_files(config)
                ToasttyLog.info(
                    "Loaded Ghostty config from TOASTTY_GHOSTTY_CONFIG_PATH",
                    category: .ghostty,
                    metadata: [
                        "path": envPath,
                    ]
                )
                return .envPath
            }

            ToasttyLog.warning(
                "Configured Ghostty config path does not exist; falling back",
                category: .ghostty,
                metadata: [
                    "path": envPath,
                ]
            )
            return loadFallbackGhosttyConfig(config, environment: environment)
        }

        return loadFallbackGhosttyConfig(config, environment: environment)
    }

    private static func loadFallbackGhosttyConfig(
        _ config: ghostty_config_t,
        environment: [String: String]
    ) -> GhosttyConfigSource {
        if let userConfigPath = userGhosttyConfigPath(environment: environment) {
            userConfigPath.withCString { pathPointer in
                ghostty_config_load_file(config, pathPointer)
            }
            ghostty_config_load_recursive_files(config)
            ToasttyLog.info(
                "Loaded Ghostty config from user path",
                category: .ghostty,
                metadata: [
                    "path": userConfigPath,
                ]
            )
            return .userPath
        }

        ghostty_config_load_default_files(config)
        ToasttyLog.info(
            "Loaded Ghostty config from default search paths",
            category: .ghostty
        )
        return .defaultFiles
    }

    private static func userGhosttyConfigPath(environment: [String: String]) -> String? {
        var candidatePaths: [String] = []
        if let xdgConfigHomePath = normalizedConfigPath(from: environment["XDG_CONFIG_HOME"]) {
            candidatePaths.append(
                URL(fileURLWithPath: xdgConfigHomePath, isDirectory: true)
                    .appendingPathComponent("ghostty/config")
                    .standardizedFileURL
                    .path
            )
        }
        candidatePaths.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/ghostty/config")
                .standardizedFileURL
                .path
        )

        var visited = Set<String>()
        for candidatePath in candidatePaths where visited.insert(candidatePath).inserted {
            if isRegularFile(at: candidatePath) {
                return candidatePath
            }
        }
        return nil
    }

    private static func isRegularFile(at path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    private static func normalizedConfigPath(from rawPath: String?) -> String? {
        guard let trimmedPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmedPath.isEmpty == false else {
            return nil
        }
        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        guard expandedPath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on"
    }

    private static func logGhosttyConfigDiagnostics(_ config: ghostty_config_t, source: GhosttyConfigSource) {
        let diagnosticsCount = ghostty_config_diagnostics_count(config)
        ToasttyLog.info(
            "Ghostty config load complete",
            category: .ghostty,
            metadata: [
                "source": source.rawValue,
                "diagnostic_count": String(diagnosticsCount),
            ]
        )
        guard diagnosticsCount > 0 else { return }

        for index in 0..<diagnosticsCount {
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            let message: String
            if let diagnosticMessage = diagnostic.message {
                message = String(cString: diagnosticMessage)
            } else {
                message = "unknown diagnostic"
            }
            ToasttyLog.warning(
                "Ghostty config diagnostic",
                category: .ghostty,
                metadata: [
                    "source": source.rawValue,
                    "index": String(index),
                    "message": message,
                ]
            )
        }
    }

    private static func applyHostStyle(_ config: ghostty_config_t) {
        let unfocusedSplitStyle = resolveUnfocusedSplitStyle(config)
        GhosttyHostStyleStore.shared.setUnfocusedSplitStyle(unfocusedSplitStyle)
        ToasttyLog.info(
            "Applied Ghostty unfocused split style",
            category: .ghostty,
            metadata: [
                "overlay_opacity": String(format: "%.3f", unfocusedSplitStyle.fillOverlayOpacity),
                "fill_rgb": String(
                    format: "%.3f,%.3f,%.3f",
                    unfocusedSplitStyle.fillColor.red,
                    unfocusedSplitStyle.fillColor.green,
                    unfocusedSplitStyle.fillColor.blue
                ),
            ]
        )
    }

    private static func resolveUnfocusedSplitStyle(_ config: ghostty_config_t) -> GhosttyUnfocusedSplitStyle {
        var configuredUnfocusedSplitOpacity = 0.7
        let opacityKey = "unfocused-split-opacity"
        if !ghostty_config_get(config, &configuredUnfocusedSplitOpacity, opacityKey, UInt(opacityKey.lengthOfBytes(using: .utf8))) {
            ToasttyLog.warning(
                "Ghostty config missing unfocused split opacity; using fallback",
                category: .ghostty,
                metadata: [
                    "key": opacityKey,
                    "fallback": "0.7",
                ]
            )
        }

        var fillColor = ghostty_config_color_s()
        let fillKey = "unfocused-split-fill"
        if !ghostty_config_get(config, &fillColor, fillKey, UInt(fillKey.lengthOfBytes(using: .utf8))) {
            let backgroundKey = "background"
            if !ghostty_config_get(config, &fillColor, backgroundKey, UInt(backgroundKey.lengthOfBytes(using: .utf8))) {
                ToasttyLog.warning(
                    "Ghostty config missing unfocused split fill and background; using black fallback",
                    category: .ghostty,
                    metadata: [
                        "fill_key": fillKey,
                        "background_key": backgroundKey,
                    ]
                )
            }
        }

        let rawOverlayOpacity = 1 - configuredUnfocusedSplitOpacity
        let overlayOpacity = min(max(rawOverlayOpacity, 0), 1)
        if abs(overlayOpacity - rawOverlayOpacity) > AppState.terminalFontComparisonEpsilon {
            ToasttyLog.warning(
                "Clamped Ghostty unfocused split overlay opacity",
                category: .ghostty,
                metadata: [
                    "raw_value": String(rawOverlayOpacity),
                    "clamped_value": String(overlayOpacity),
                ]
            )
        }

        return GhosttyUnfocusedSplitStyle(
            fillOverlayOpacity: overlayOpacity,
            fillColor: GhosttyHostColor(
                red: Double(fillColor.r) / 255,
                green: Double(fillColor.g) / 255,
                blue: Double(fillColor.b) / 255
            )
        )
    }

    private static func resolveConfiguredTerminalFontPoints(_ config: ghostty_config_t) -> Double? {
        // ghostty_config_get writes C float values for font-size.
        var configuredFontPoints = Float(AppState.defaultTerminalFontPoints)
        let fontSizeKey = "font-size"
        guard ghostty_config_get(
            config,
            &configuredFontPoints,
            fontSizeKey,
            UInt(fontSizeKey.lengthOfBytes(using: .utf8))
        ) else {
            ToasttyLog.info(
                "Ghostty config missing font size; using Toastty fallback",
                category: .ghostty,
                metadata: [
                    "key": fontSizeKey,
                    "fallback": String(format: "%.2f", AppState.defaultTerminalFontPoints),
                ]
            )
            return nil
        }

        let rawConfiguredFontPoints = Double(configuredFontPoints)
        let clampedFontPoints = AppState.clampedTerminalFontPoints(rawConfiguredFontPoints)
        if abs(clampedFontPoints - rawConfiguredFontPoints) > AppState.terminalFontComparisonEpsilon {
            ToasttyLog.warning(
                "Clamped Ghostty configured font size to Toastty bounds",
                category: .ghostty,
                metadata: [
                    "raw_value": String(format: "%.2f", rawConfiguredFontPoints),
                    "clamped_value": String(format: "%.2f", clampedFontPoints),
                    "min": String(format: "%.2f", AppState.minTerminalFontPoints),
                    "max": String(format: "%.2f", AppState.maxTerminalFontPoints),
                ]
            )
        }

        ToasttyLog.info(
            "Resolved Ghostty configured terminal font size",
            category: .ghostty,
            metadata: [
                "points": String(format: "%.2f", clampedFontPoints),
            ]
        )
        return clampedFontPoints
    }

    fileprivate func scheduleImmediateTick() {
        DispatchQueue.main.async { [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    fileprivate func routeRuntimeAction(_ action: GhosttyRuntimeAction) -> Bool {
        actionHandler?.handleGhosttyRuntimeAction(action) ?? false
    }
}
#endif
