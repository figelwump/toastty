#if TOASTTY_HAS_GHOSTTY_KIT
import AppKit
import Foundation
import GhosttyKit

@MainActor
final class GhosttyRuntimeManager {
    static let shared = GhosttyRuntimeManager()

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

        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                guard let userdata else { return }
                let manager = Unmanaged<GhosttyRuntimeManager>.fromOpaque(userdata).takeUnretainedValue()
                manager.scheduleImmediateTick()
            },
            action_cb: { _, _, _ in
                true
            },
            read_clipboard_cb: { _, _, _ in },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            close_surface_cb: { _, _ in }
        )

        app = ghostty_app_new(&runtimeConfig, config)
        if app == nil, let data = "toastty ghostty error: ghostty_app_new returned nil\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        scheduleImmediateTick()
    }

    func makeSurface(
        panelID: UUID,
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

        let panelIdentifier = panelID.uuidString
        let surface = workingDirectory.withCString { cwdPointer in
            panelIdentifier.withCString { inputPointer in
                surfaceConfig.working_directory = cwdPointer
                surfaceConfig.initial_input = inputPointer
                return ghostty_surface_new(app, &surfaceConfig)
            }
        }
        scheduleImmediateTick()
        return surface
    }

    private static func initializeGhosttyRuntime() -> Bool {
        ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
    }

    private func scheduleImmediateTick() {
        DispatchQueue.main.async { [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }
}
#endif
