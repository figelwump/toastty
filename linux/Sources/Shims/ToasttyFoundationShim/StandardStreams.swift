#if os(Linux)
@preconcurrency import Glibc

/// Glibc imports `stderr`/`stdout` as mutable globals, which Swift 6 rejects
/// as shared mutable state; Darwin's are effectively constant. These shadow
/// the Glibc ones for shared code (this module imports Glibc, so its
/// declarations win name lookup).
nonisolated(unsafe) public let stderr: UnsafeMutablePointer<FILE> = Glibc.stderr
nonisolated(unsafe) public let stdout: UnsafeMutablePointer<FILE> = Glibc.stdout
#endif
