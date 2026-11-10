import CGtk

private final class SourceBox: @unchecked Sendable {
    let handler: @MainActor () -> Bool
    init(_ handler: @escaping @MainActor () -> Bool) { self.handler = handler }
}

private let sourceTrampoline: @convention(c) (gpointer?) -> gboolean = { data in
    let box = Unmanaged<SourceBox>.fromOpaque(data!).takeUnretainedValue()
    return MainActor.assumeIsolated { box.handler() }.gboolean
}

private let sourceDestroy: @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<SourceBox>.fromOpaque(data).release()
}

/// Main-loop dispatch. GTK is single-threaded; work from other threads must
/// hop here (GLib's default main context is thread-safe to add sources to).
public enum MainLoop {
    /// Runs `body` once on the next main-loop iteration.
    @discardableResult
    public static func idle(priority: Int32 = Int32(G_PRIORITY_DEFAULT_IDLE), _ body: @escaping @MainActor () -> Void) -> guint {
        let box = SourceBox { body(); return false }
        return g_idle_add_full(priority, sourceTrampoline, Unmanaged.passRetained(box).toOpaque(), sourceDestroy)
    }

    /// Runs `body` after `milliseconds`; return true from `body` to repeat.
    @discardableResult
    public static func timeout(milliseconds: UInt32, _ body: @escaping @MainActor () -> Bool) -> guint {
        let box = SourceBox(body)
        return g_timeout_add_full(Int32(G_PRIORITY_DEFAULT), milliseconds, sourceTrampoline, Unmanaged.passRetained(box).toOpaque(), sourceDestroy)
    }

    public static func cancel(_ sourceID: guint) {
        guard sourceID != 0 else { return }
        g_source_remove(sourceID)
    }

    /// Hops to the main thread from any thread.
    public static func dispatch(_ body: @escaping @MainActor @Sendable () -> Void) {
        idle(priority: Int32(G_PRIORITY_DEFAULT), body)
    }

    /// Iterates the default main context until `condition` holds or the
    /// timeout passes. Test/automation helper; never call from a signal
    /// handler that can re-enter itself.
    @MainActor
    @discardableResult
    public static func spin(untilMilliseconds timeout: Int, _ condition: () -> Bool = { false }) -> Bool {
        let deadline = g_get_monotonic_time() + Int(timeout) * 1000
        while g_get_monotonic_time() < deadline {
            if condition() { return true }
            g_main_context_iteration(nil, 0)
            g_usleep(2000)
        }
        return condition()
    }
}
