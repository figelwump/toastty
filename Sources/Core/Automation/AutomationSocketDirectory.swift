import Darwin
import Foundation

/// Ownership checks for the automation socket directory and the sockets in it.
///
/// The default socket directory has a predictable name
/// (`<base>/toastty-<uid>` or `$XDG_RUNTIME_DIR/toastty`). When its parent is
/// shared, such as `/tmp`, another local account could create that directory
/// first and then plant a socket or `current-socket.json`, so CLI and agent
/// clients would talk to that account's process. The server therefore never
/// listens in another user's directory, clients only read discovery data from
/// a directory they own that no one else can write to, and clients only
/// connect to sockets owned by their own user.
public enum AutomationSocketDirectory {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notADirectory(path: String)
        case ownedByAnotherUser(path: String, ownerID: UInt32)
        case writableByOthers(path: String, mode: UInt32)
        case inspectionFailed(path: String, errorNumber: Int32)

        public var description: String {
            switch self {
            case .notADirectory(let path):
                return "automation socket directory is not a directory: \(path)"
            case .ownedByAnotherUser(let path, let ownerID):
                return "automation socket directory is owned by another user (uid \(ownerID)): \(path)"
            case .writableByOthers(let path, let mode):
                return "automation socket directory is writable by other users (mode \(String(mode & 0o7777, radix: 8))): \(path)"
            case .inspectionFailed(let path, let errorNumber):
                return "failed to inspect automation socket directory \(path): \(String(cString: strerror(errorNumber)))"
            }
        }
    }

    private static let fileTypeMask: UInt32 = 0o170000
    private static let directoryType: UInt32 = 0o040000
    private static let symbolicLinkType: UInt32 = 0o120000
    private static let groupOrOtherWriteBits: UInt32 = 0o022
    private static let stickyBit: UInt32 = 0o1000

    /// Prepares the directory a server socket is bound in, creating it (and
    /// missing parents) first:
    /// - a shared sticky directory such as `/tmp` (for an explicit
    ///   `TOASTTY_SOCKET_PATH`) owned by root or the current user is used
    ///   as is: others cannot replace a socket there;
    /// - a directory the current user owns is restricted to 0700;
    /// - a root-owned directory others cannot write to is used as is;
    /// - anything else, such as another user's directory, throws.
    public static func prepareSocketDirectory(at url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let path = url.path
        let info = try inspectDirectory(path: path)
        let ownerID = UInt32(info.st_uid)
        let mode = UInt32(info.st_mode)
        let currentUserID = UInt32(geteuid())
        if mode & stickyBit != 0, mode & groupOrOtherWriteBits != 0 {
            guard ownerID == currentUserID || ownerID == 0 else {
                throw Failure.ownedByAnotherUser(path: path, ownerID: ownerID)
            }
            return
        }
        if ownerID == currentUserID {
            guard chmod(path, 0o700) == 0 else {
                throw Failure.inspectionFailed(path: path, errorNumber: errno)
            }
            try validateTrusted(path: path)
            return
        }
        guard ownerID == 0 else {
            throw Failure.ownedByAnotherUser(path: path, ownerID: ownerID)
        }
        guard mode & groupOrOtherWriteBits == 0 else {
            throw Failure.writableByOthers(path: path, mode: mode)
        }
    }

    /// Whether `path` is a directory owned by the current user that no other
    /// user can write to (see `inspectDirectory` for symlinks).
    public static func isTrustedDirectory(atPath path: String) -> Bool {
        (try? validateTrusted(path: path)) != nil
    }

    /// Whether the file at `path` (following symlinks) belongs to the current
    /// user, or `nil` if it cannot be inspected (for example, it is missing),
    /// so callers can report their own error.
    public static func isOwnedByCurrentUser(atPath path: String) -> Bool? {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return nil
        }
        return UInt32(info.st_uid) == UInt32(geteuid())
    }

    static func validateTrusted(path: String) throws {
        let info = try inspectDirectory(path: path)
        let ownerID = UInt32(info.st_uid)
        guard ownerID == UInt32(geteuid()) else {
            throw Failure.ownedByAnotherUser(path: path, ownerID: ownerID)
        }
        let mode = UInt32(info.st_mode)
        guard mode & groupOrOtherWriteBits == 0 else {
            throw Failure.writableByOthers(path: path, mode: mode)
        }
    }

    /// `stat` of the directory at `path`. A symlink is followed only if the
    /// current user or root owns the link itself (macOS `/tmp` ->
    /// `/private/tmp`), so another user cannot redirect a predictable path.
    private static func inspectDirectory(path: String) throws -> stat {
        var linkInfo = stat()
        guard lstat(path, &linkInfo) == 0 else {
            throw Failure.inspectionFailed(path: path, errorNumber: errno)
        }
        if UInt32(linkInfo.st_mode) & fileTypeMask == symbolicLinkType {
            let linkOwnerID = UInt32(linkInfo.st_uid)
            guard linkOwnerID == UInt32(geteuid()) || linkOwnerID == 0 else {
                throw Failure.ownedByAnotherUser(path: path, ownerID: linkOwnerID)
            }
        }
        var info = stat()
        guard stat(path, &info) == 0 else {
            throw Failure.inspectionFailed(path: path, errorNumber: errno)
        }
        guard UInt32(info.st_mode) & fileTypeMask == directoryType else {
            throw Failure.notADirectory(path: path)
        }
        return info
    }
}
