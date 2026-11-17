import CGtk
import CGtkShim

// Swift closures attached to GObject signals.
//
// Each closure is boxed in a retained class instance passed as the signal's
// `user_data`; GLib releases it through the destroy notify when the handler
// is disconnected or the instance is finalized, so closures never outlive
// their emitter and never leak. GTK only emits on the main thread, so the
// trampolines assume main-actor isolation.

private final class SignalBox<F>: @unchecked Sendable {
    let handler: F
    init(_ handler: F) { self.handler = handler }
}

private let releaseBox: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

@inline(__always)
private func box<F>(_ data: gpointer?) -> SignalBox<F> {
    Unmanaged<SignalBox<F>>.fromOpaque(data!).takeUnretainedValue()
}

public typealias VoidHandler = @MainActor () -> Void
public typealias BoolHandler = @MainActor () -> Bool
public typealias PointerHandler = @MainActor (UnsafeMutableRawPointer?) -> Void
public typealias KeyHandler = @MainActor (_ keyval: UInt32, _ keycode: UInt32, _ state: GdkModifierType) -> Bool
public typealias KeyReleaseHandler = @MainActor (_ keyval: UInt32, _ keycode: UInt32, _ state: GdkModifierType) -> Void
public typealias PressHandler = @MainActor (_ nPress: Int32, _ x: Double, _ y: Double) -> Void
public typealias DoubleHandler = @MainActor (Double, Double) -> Void
public typealias UIntHandler = @MainActor (UInt32) -> Void
public typealias PointerBoolHandler = @MainActor (UnsafeMutableRawPointer?) -> Bool
public typealias PointerUIntHandler = @MainActor (UnsafeMutableRawPointer?, UInt32) -> Void

// (instance, user_data)
private let voidTrampoline: @convention(c) (gpointer?, gpointer?) -> Void = { _, data in
    let b: SignalBox<VoidHandler> = box(data)
    MainActor.assumeIsolated { b.handler() }
}

// (instance, user_data) -> gboolean
private let boolTrampoline: @convention(c) (gpointer?, gpointer?) -> gboolean = { _, data in
    let b: SignalBox<BoolHandler> = box(data)
    return MainActor.assumeIsolated { b.handler() }.gboolean
}

// (instance, arg, user_data)
private let pointerTrampoline: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, arg, data in
    let b: SignalBox<PointerHandler> = box(data)
    nonisolated(unsafe) let arg = arg
    MainActor.assumeIsolated { b.handler(arg) }
}

// (instance, arg, user_data) -> gboolean
private let pointerBoolTrampoline: @convention(c) (gpointer?, gpointer?, gpointer?) -> gboolean = { _, arg, data in
    let b: SignalBox<PointerBoolHandler> = box(data)
    nonisolated(unsafe) let arg = arg
    return MainActor.assumeIsolated { b.handler(arg) }.gboolean
}

// (instance, arg, guint, user_data)
private let pointerUIntTrampoline: @convention(c) (gpointer?, gpointer?, guint, gpointer?) -> Void = { _, arg, value, data in
    let b: SignalBox<PointerUIntHandler> = box(data)
    nonisolated(unsafe) let arg = arg
    MainActor.assumeIsolated { b.handler(arg, value) }
}

// (instance, guint, user_data)
private let uintTrampoline: @convention(c) (gpointer?, guint, gpointer?) -> Void = { _, value, data in
    let b: SignalBox<UIntHandler> = box(data)
    MainActor.assumeIsolated { b.handler(value) }
}

// GtkEventControllerKey::key-pressed (controller, keyval, keycode, state, user_data) -> gboolean
private let keyTrampoline: @convention(c) (gpointer?, guint, guint, GdkModifierType, gpointer?) -> gboolean = {
    _, keyval, keycode, state, data in
    let b: SignalBox<KeyHandler> = box(data)
    return MainActor.assumeIsolated { b.handler(keyval, keycode, state) }.gboolean
}

// GtkEventControllerKey::key-released
private let keyReleaseTrampoline: @convention(c) (gpointer?, guint, guint, GdkModifierType, gpointer?) -> Void = {
    _, keyval, keycode, state, data in
    let b: SignalBox<KeyReleaseHandler> = box(data)
    MainActor.assumeIsolated { b.handler(keyval, keycode, state) }
}

// GtkGestureClick::pressed / released (gesture, n_press, x, y, user_data)
private let pressTrampoline: @convention(c) (gpointer?, gint, gdouble, gdouble, gpointer?) -> Void = {
    _, nPress, x, y, data in
    let b: SignalBox<PressHandler> = box(data)
    MainActor.assumeIsolated { b.handler(nPress, x, y) }
}

// (instance, double, double, user_data) — drag-begin/drag-update/motion.
private let doubleTrampoline: @convention(c) (gpointer?, gdouble, gdouble, gpointer?) -> Void = { _, x, y, data in
    let b: SignalBox<DoubleHandler> = box(data)
    MainActor.assumeIsolated { b.handler(x, y) }
}

public typealias PrepareHandler = @MainActor (Double, Double) -> UnsafeMutableRawPointer?
public typealias DropHandler = @MainActor (_ value: UnsafeRawPointer?, _ x: Double, _ y: Double) -> Bool
public typealias DropMotionHandler = @MainActor (Double, Double) -> UInt32

// GtkDragSource::prepare (source, x, y, user_data) -> GdkContentProvider*
private let prepareTrampoline: @convention(c) (gpointer?, gdouble, gdouble, gpointer?) -> gpointer? = { _, x, y, data in
    let b: SignalBox<PrepareHandler> = box(data)
    nonisolated(unsafe) var result: gpointer? = nil
    MainActor.assumeIsolated { result = b.handler(x, y) }
    return result
}

// GtkDropTarget::drop (target, const GValue*, x, y, user_data) -> gboolean
private let dropTrampoline: @convention(c) (gpointer?, gpointer?, gdouble, gdouble, gpointer?) -> gboolean = { _, value, x, y, data in
    let b: SignalBox<DropHandler> = box(data)
    nonisolated(unsafe) let value = value
    return MainActor.assumeIsolated { b.handler(UnsafeRawPointer(value), x, y) }.gboolean
}

// GtkDropTarget::enter / motion (target, x, y, user_data) -> GdkDragAction
private let dropMotionTrampoline: @convention(c) (gpointer?, gdouble, gdouble, gpointer?) -> guint32 = { _, x, y, data in
    let b: SignalBox<DropMotionHandler> = box(data)
    return MainActor.assumeIsolated { b.handler(x, y) }
}

@MainActor
public enum Signal {
    @discardableResult
    public static func connectDragPrepare(_ source: some GPointer, _ handler: @escaping PrepareHandler) -> gulong {
        connectRaw(source, "prepare", trampoline: unsafeBitCast(prepareTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: false)
    }

    @discardableResult
    public static func connectDrop(_ target: some GPointer, _ handler: @escaping DropHandler) -> gulong {
        connectRaw(target, "drop", trampoline: unsafeBitCast(dropTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: false)
    }

    /// `enter` or `motion` on a `GtkDropTarget`; return a `GdkDragAction`.
    @discardableResult
    public static func connectDropMotion(_ target: some GPointer, _ name: String, _ handler: @escaping DropMotionHandler) -> gulong {
        connectRaw(target, name, trampoline: unsafeBitCast(dropMotionTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: false)
    }

    @discardableResult
    private static func connectRaw<F>(
        _ instance: some GPointer,
        _ name: String,
        trampoline: UnsafeMutableRawPointer,
        handler: F,
        after: Bool
    ) -> gulong {
        let data = Unmanaged.passRetained(SignalBox(handler)).toOpaque()
        return toastty_signal_connect(instance.rawGPointer, name, trampoline, data, releaseBox, after.gboolean)
    }

    @discardableResult
    public static func connect(_ instance: some GPointer, _ name: String, after: Bool = false, _ handler: @escaping VoidHandler) -> gulong {
        connectRaw(instance, name, trampoline: unsafeBitCast(voidTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: after)
    }

    @discardableResult
    public static func connectBool(_ instance: some GPointer, _ name: String, after: Bool = false, _ handler: @escaping BoolHandler) -> gulong {
        connectRaw(instance, name, trampoline: unsafeBitCast(boolTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: after)
    }

    @discardableResult
    public static func connectPointer(_ instance: some GPointer, _ name: String, after: Bool = false, _ handler: @escaping PointerHandler) -> gulong {
        connectRaw(instance, name, trampoline: unsafeBitCast(pointerTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: after)
    }

    @discardableResult
    public static func connectPointerBool(_ instance: some GPointer, _ name: String, after: Bool = false, _ handler: @escaping PointerBoolHandler) -> gulong {
        connectRaw(instance, name, trampoline: unsafeBitCast(pointerBoolTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: after)
    }

    @discardableResult
    public static func connectPointerUInt(_ instance: some GPointer, _ name: String, after: Bool = false, _ handler: @escaping PointerUIntHandler) -> gulong {
        connectRaw(instance, name, trampoline: unsafeBitCast(pointerUIntTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: after)
    }

    @discardableResult
    public static func connectUInt(_ instance: some GPointer, _ name: String, after: Bool = false, _ handler: @escaping UIntHandler) -> gulong {
        connectRaw(instance, name, trampoline: unsafeBitCast(uintTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: after)
    }

    @discardableResult
    public static func connectKeyPressed(_ controller: some GPointer, _ handler: @escaping KeyHandler) -> gulong {
        connectRaw(controller, "key-pressed", trampoline: unsafeBitCast(keyTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: false)
    }

    @discardableResult
    public static func connectKeyReleased(_ controller: some GPointer, _ handler: @escaping KeyReleaseHandler) -> gulong {
        connectRaw(controller, "key-released", trampoline: unsafeBitCast(keyReleaseTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: false)
    }

    @discardableResult
    public static func connectPress(_ gesture: some GPointer, _ name: String = "pressed", _ handler: @escaping PressHandler) -> gulong {
        connectRaw(gesture, name, trampoline: unsafeBitCast(pressTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: false)
    }

    @discardableResult
    public static func connectDoubles(_ instance: some GPointer, _ name: String, _ handler: @escaping DoubleHandler) -> gulong {
        connectRaw(instance, name, trampoline: unsafeBitCast(doubleTrampoline, to: UnsafeMutableRawPointer.self), handler: handler, after: false)
    }

    /// `notify::<property>`.
    @discardableResult
    public static func notify(_ instance: some GPointer, _ property: String, _ handler: @escaping VoidHandler) -> gulong {
        connectPointer(instance, "notify::\(property)") { _ in handler() }
    }

    public static func disconnect(_ instance: some GPointer, _ handlerID: gulong) {
        g_signal_handler_disconnect(instance.rawGPointer, handlerID)
    }

    public static func block(_ instance: some GPointer, _ handlerID: gulong) {
        g_signal_handler_block(instance.rawGPointer, handlerID)
    }

    public static func unblock(_ instance: some GPointer, _ handlerID: gulong) {
        g_signal_handler_unblock(instance.rawGPointer, handlerID)
    }
}
