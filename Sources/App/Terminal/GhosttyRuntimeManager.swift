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
}

private final class GhosttyActionCallbackResult: @unchecked Sendable {
    var handled = false
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
    guard let app else { return false }
    guard let userdata = ghostty_app_userdata(app) else { return false }
    guard let runtimeAction = makeGhosttyRuntimeAction(target: target, action: action) else {
        return false
    }

    // Keep callback semantics synchronous for Ghostty while safely hopping to main when needed.
    let managerHandle = UInt(bitPattern: userdata)
    if Thread.isMainThread {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: managerHandle) else {
            return false
        }
        let manager = Unmanaged<GhosttyRuntimeManager>.fromOpaque(pointer).takeUnretainedValue()
        return MainActor.assumeIsolated {
            manager.routeRuntimeAction(runtimeAction)
        }
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
        if let data = "toastty ghostty warning: action callback timed out waiting for main queue\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        return false
    }
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

    fileprivate func routeRuntimeAction(_ action: GhosttyRuntimeAction) -> Bool {
        actionHandler?.handleGhosttyRuntimeAction(action) ?? false
    }
}
#endif
