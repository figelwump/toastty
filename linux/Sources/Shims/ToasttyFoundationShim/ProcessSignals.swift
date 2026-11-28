import Glibc

/// Darwin's per-descriptor `fcntl(fd, F_SETNOSIGPIPE, 1)` has no Linux
/// counterpart. Reading this constant ignores SIGPIPE process-wide (once) so
/// the guarded write gets EPIPE like on macOS, then yields an invalid fcntl
/// command, so the call itself fails harmlessly with EINVAL. Toastty's Linux
/// processes ignore SIGPIPE anyway (`LinuxProcessSignals`).
public var F_SETNOSIGPIPE: Int32 {
    LinuxProcessSignals.ignoreSIGPIPE()
    return -1
}

public enum LinuxProcessSignals {
    private static let ignoreOnce: Void = {
        _ = signal(SIGPIPE, SIG_IGN)
    }()

    /// Writes to closed pipes and sockets fail with EPIPE instead of killing
    /// the process (Darwin code relies on SO_NOSIGPIPE/F_SETNOSIGPIPE).
    public static func ignoreSIGPIPE() {
        _ = ignoreOnce
    }
}
