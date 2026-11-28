import Foundation
#if canImport(Glibc)
@_exported import Glibc
#endif

// Darwin-only libc spellings. Shared App code's `Darwin.`-qualified calls
// mirror as `ToasttyAppKitShim.` (manifest `darwinQualifier`), which finds
// these and every re-exported Glibc symbol.

private typealias RemoveXattrFunction = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32

nonisolated(unsafe) private let linuxRemoveXattr: RemoveXattrFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "removexattr") else { return nil }
    return unsafeBitCast(symbol, to: RemoveXattrFunction.self)
}()

/// Darwin's removexattr(path, name, options). Linux's libc call has no
/// options argument. `com.apple.*` attributes never exist on Linux, so the
/// usual result is -1/ENODATA, which callers ignore like on macOS.
@discardableResult
public func removexattr(_ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ options: Int32) -> Int32 {
    _ = options
    guard let linuxRemoveXattr else {
        errno = ENOSYS
        return -1
    }
    return linuxRemoveXattr(path, name)
}
