#if os(Linux)
import Glibc

// Darwin spellings of POSIX fields and constants that shared code uses.
// Behavior is identical; only names differ between Darwin and Glibc.

extension stat {
    public var st_mtimespec: timespec { st_mtim }
    public var st_ctimespec: timespec { st_ctim }
    public var st_atimespec: timespec { st_atim }
}

public let MAXPATHLEN = Int32(PATH_MAX)
#endif

#if os(Linux)
/// Darwin's F_FULLFSYNC has no Linux counterpart because fsync(2) already
/// flushes through the device cache. An invalid command makes fcntl fail with
/// EINVAL, which shared code treats as "use fsync" — the correct Linux call.
public let F_FULLFSYNC: Int32 = -1
#endif

#if os(Linux)
public typealias __darwin_suseconds_t = suseconds_t

/// Glibc imports SOCK_STREAM/SOCK_DGRAM as the `__socket_type` enum while
/// Darwin exposes plain Int32 constants. This overload lets shared
/// `socket(AF_UNIX, SOCK_STREAM, 0)` calls compile unchanged.
@inlinable
public func socket(_ domain: Int32, _ type: __socket_type, _ protocolNumber: Int32) -> Int32 {
    Glibc.socket(domain, Int32(type.rawValue), protocolNumber)
}
#endif

#if os(Linux)
/// Darwin's `_NSGetExecutablePath`, backed by /proc/self/exe. Same contract:
/// returns 0 and writes a NUL-terminated path when `buffer` holds `*size`
/// bytes; otherwise returns -1 and stores the required size in `*size`.
@discardableResult
public func _NSGetExecutablePath(
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ size: UnsafeMutablePointer<UInt32>
) -> Int32 {
    var path = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlink("/proc/self/exe", &path, path.count - 1)
    guard count > 0 else { return -1 }
    let required = UInt32(count + 1)
    guard let buffer, size.pointee >= required else {
        size.pointee = required
        return -1
    }
    path.withUnsafeBufferPointer { source in
        buffer.update(from: source.baseAddress!, count: count)
    }
    buffer[count] = 0
    return 0
}
#endif

#if os(Linux)
/// Darwin declares posix_spawn's argv/envp as implicitly unwrapped pointers;
/// Glibc's are non-optional. Accept the Darwin shape and forward.
@inlinable
public func posix_spawn(
    _ pid: UnsafeMutablePointer<pid_t>!,
    _ path: UnsafePointer<CChar>!,
    _ fileActions: UnsafePointer<posix_spawn_file_actions_t>?,
    _ attributes: UnsafePointer<posix_spawnattr_t>?,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let argv, let envp else { return EINVAL }
    return Glibc.posix_spawn(pid, path, fileActions, attributes, argv, envp)
}
#endif
