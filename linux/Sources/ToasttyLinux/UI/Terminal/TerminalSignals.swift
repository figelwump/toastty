import CGtk
import CGtkShim

// Typed trampolines for `ToasttyGhosttySurface` signals whose C signatures
// the generic helpers in GLib/Signals.swift do not cover (integer and
// 64-bit arguments must be declared exactly, not read as pointers).

private final class TerminalSignalBox<F>: @unchecked Sendable {
    let handler: F
    init(_ handler: F) { self.handler = handler }
}

private let releaseTerminalBox: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

@inline(__always)
private func unbox<F>(_ data: gpointer?) -> TerminalSignalBox<F> {
    Unmanaged<TerminalSignalBox<F>>.fromOpaque(data!).takeUnretainedValue()
}

typealias IntHandler = @MainActor (Int32) -> Void
typealias IntBoolHandler = @MainActor (Int32) -> Bool
typealias UIntUInt64Handler = @MainActor (UInt32, UInt64) -> Void
typealias IntUInt64Handler = @MainActor (Int32, UInt64) -> Void
typealias StringHandler = @MainActor (String?) -> Void

// (instance, gint/gboolean, user_data)
private let intTrampoline: @convention(c) (gpointer?, gint, gpointer?) -> Void = { _, value, data in
    let b: TerminalSignalBox<IntHandler> = unbox(data)
    MainActor.assumeIsolated { b.handler(value) }
}

// (instance, gint, user_data) -> gboolean
private let intBoolTrampoline: @convention(c) (gpointer?, gint, gpointer?) -> gboolean = { _, value, data in
    let b: TerminalSignalBox<IntBoolHandler> = unbox(data)
    return MainActor.assumeIsolated { b.handler(value) } ? 1 : 0
}

// (instance, guint, guint64, user_data)
private let uintUInt64Trampoline: @convention(c) (gpointer?, guint, guint64, gpointer?) -> Void = { _, a, b64, data in
    let b: TerminalSignalBox<UIntUInt64Handler> = unbox(data)
    MainActor.assumeIsolated { b.handler(a, UInt64(b64)) }
}

// (instance, gint, guint64, user_data)
private let intUInt64Trampoline: @convention(c) (gpointer?, gint, guint64, gpointer?) -> Void = { _, a, b64, data in
    let b: TerminalSignalBox<IntUInt64Handler> = unbox(data)
    MainActor.assumeIsolated { b.handler(a, UInt64(b64)) }
}

// (instance, const char *, user_data)
private let stringTrampoline: @convention(c) (gpointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, value, data in
    let b: TerminalSignalBox<StringHandler> = unbox(data)
    let string = value.map { String(cString: $0) }
    MainActor.assumeIsolated { b.handler(string) }
}

@MainActor
enum TerminalSignal {
    private static func connect<F>(_ instance: some GPointer, _ name: String, _ trampoline: UnsafeMutableRawPointer, _ handler: F) {
        let data = Unmanaged.passRetained(TerminalSignalBox(handler)).toOpaque()
        _ = toastty_signal_connect(instance.rawGPointer, name, trampoline, data, releaseTerminalBox, 0)
    }

    static func connectInt(_ instance: some GPointer, _ name: String, _ handler: @escaping IntHandler) {
        connect(instance, name, unsafeBitCast(intTrampoline, to: UnsafeMutableRawPointer.self), handler)
    }

    static func connectIntBool(_ instance: some GPointer, _ name: String, _ handler: @escaping IntBoolHandler) {
        connect(instance, name, unsafeBitCast(intBoolTrampoline, to: UnsafeMutableRawPointer.self), handler)
    }

    static func connectUIntUInt64(_ instance: some GPointer, _ name: String, _ handler: @escaping UIntUInt64Handler) {
        connect(instance, name, unsafeBitCast(uintUInt64Trampoline, to: UnsafeMutableRawPointer.self), handler)
    }

    static func connectIntUInt64(_ instance: some GPointer, _ name: String, _ handler: @escaping IntUInt64Handler) {
        connect(instance, name, unsafeBitCast(intUInt64Trampoline, to: UnsafeMutableRawPointer.self), handler)
    }

    static func connectString(_ instance: some GPointer, _ name: String, _ handler: @escaping StringHandler) {
        connect(instance, name, unsafeBitCast(stringTrampoline, to: UnsafeMutableRawPointer.self), handler)
    }
}
