#if TOASTTY_HAS_GHOSTTY_KIT
import AppKit
import Foundation
import GhosttyKit

@MainActor
protocol GhosttyRuntimeActionHandling: AnyObject {
    func handleGhosttyRuntimeAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool
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
    guard let app else { return false }
    guard let userdata = ghostty_app_userdata(app) else { return false }

    let manager = Unmanaged<GhosttyRuntimeManager>.fromOpaque(userdata).takeUnretainedValue()
    if Thread.isMainThread {
        return MainActor.assumeIsolated {
            manager.routeRuntimeAction(target: target, action: action)
        }
    }

    var handled = false
    DispatchQueue.main.sync {
        handled = MainActor.assumeIsolated {
        return manager.routeRuntimeAction(target: target, action: action)
        }
    }
    return handled
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

@MainActor
final class GhosttyRuntimeManager {
    static let shared = GhosttyRuntimeManager()

    weak var actionHandler: (any GhosttyRuntimeActionHandling)?

    private var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {
        guard Self.initializeGhosttyRuntime() else {
            if let data = "toastty ghostty error: ghostty_init failed\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
            return
        }

        let config = ghostty_config_new()
        self.config = config

        ghostty_config_load_cli_args(config)
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        var runtimeConfig = makeGhosttyRuntimeConfig(
            userdata: Unmanaged.passUnretained(self).toOpaque()
        )

        app = ghostty_app_new(&runtimeConfig, config)
        if app == nil, let data = "toastty ghostty error: ghostty_app_new returned nil\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
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
        surfaceConfig.scale_factor = max(Double(hostView.window?.backingScaleFactor ?? 1), 1)
        surfaceConfig.font_size = Float(fontPoints)
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        let surface = workingDirectory.withCString { cwdPointer in
            surfaceConfig.working_directory = cwdPointer
            return ghostty_surface_new(app, &surfaceConfig)
        }
        scheduleImmediateTick()
        return surface
    }

    private static func initializeGhosttyRuntime() -> Bool {
        ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
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

    fileprivate func routeRuntimeAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        actionHandler?.handleGhosttyRuntimeAction(target: target, action: action) ?? false
    }
}
#endif
