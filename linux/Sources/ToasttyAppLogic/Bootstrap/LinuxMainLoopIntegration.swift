import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Connects Swift's main-thread executors to a foreign main loop (GLib).
///
/// The app layer schedules work with `@MainActor` tasks, `DispatchQueue.main`,
/// and `RunLoop.main` timers (OpenCombine `debounce`, `Timer`). On Linux
/// those run only when something drains libdispatch's main queue and runs
/// CFRunLoop. Under `g_application_run` nothing does, so the frontend must:
///
/// 1. watch `mainQueueFileDescriptor` for readability (`g_unix_fd_add`,
///    `G_IO_IN`) and call `drainMainQueue()` from the callback, and
/// 2. call `serviceRunLoop()` when its returned date passes (a GLib timeout
///    re-armed after every call; also call it once at startup).
///
/// Both must run on the main thread.
public enum LinuxMainLoopIntegration {
    private typealias HandleFunction = @convention(c) () -> Int32
    private typealias CallbackFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void

    nonisolated(unsafe) private static let handleFunction: HandleFunction? = symbol("_dispatch_get_main_queue_handle_4CF")
    nonisolated(unsafe) private static let callbackFunction: CallbackFunction? = symbol("_dispatch_main_queue_callback_4CF")

    private static func symbol<T>(_ name: String) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: 0), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// The libdispatch hooks resolved (they exist in every Linux libdispatch).
    public static var isAvailable: Bool {
        handleFunction != nil && callbackFunction != nil
    }

    /// The eventfd libdispatch signals when main-queue work is enqueued.
    /// `nil` once `dispatchMain()` has taken over the main queue (Swift
    /// Testing, async `main`), which a GTK app never calls.
    public static var mainQueueFileDescriptor: Int32? {
        guard let handleFunction else { return nil }
        let fd = handleFunction()
        return fd >= 0 ? fd : nil
    }

    /// Runs every block pending on the main queue (including main-actor jobs).
    @MainActor
    public static func drainMainQueue() {
        if let fd = mainQueueFileDescriptor {
            // Reset the eventfd counter without blocking.
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pollDescriptor, 1, 0) > 0 {
                var counter: UInt64 = 0
                _ = read(fd, &counter, MemoryLayout<UInt64>.size)
            }
        }
        callbackFunction?(nil)
    }

    /// Fires due `RunLoop.main` timers and sources once, then returns when the
    /// next timer is due (`nil` when none is scheduled).
    @MainActor
    @discardableResult
    public static func serviceRunLoop() -> Date? {
        RunLoop.main.limitDate(forMode: .default)
    }
}
