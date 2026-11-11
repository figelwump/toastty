import CoreState
import Darwin
import Foundation
import RemoteProtocol

/// Tells Claude Code that one folder is trusted, before Toastty starts
/// Claude Code there, so its folder-trust dialog does not come up.
///
/// Toastty uses this for the coordinator's folder only. Toastty creates that
/// folder and writes every file in it, so the question "do you trust the
/// files in this folder?" has no one else to answer it. No other folder is
/// trusted this way: for a folder with a user's or a stranger's files, the
/// dialog is the user's decision.
///
/// Claude Code keeps trust in its own config file, which every running
/// Claude Code session writes. The write here follows the rules that Claude
/// Code (2.1.322) follows for that file:
///
/// - It holds the lock: a directory named `<config file>.lock`, made with
///   `mkdir`. A session that cannot make the directory waits. A lock older
///   than 10 seconds counts as left behind, so the lock is held for one read
///   and one write only.
/// - Under the lock it reads the file again, changes that text, writes a new
///   file beside it and renames the new file over the old one. A reader sees
///   the old file or the new one, never a part.
///
/// Every Claude Code session reads the file again under the same lock before
/// its own write, so a session that writes next keeps the entry, and this
/// write keeps what the sessions wrote before. When anything is not as
/// expected, nothing is written: Claude Code then asks in its terminal, as it
/// did before, and the coordinator's chat says so.
struct ClaudeFolderTrust: Sendable {
    enum Outcome: Equatable, Sendable {
        case trusted
        /// The file names the folder as trusted already.
        case alreadyTrusted
        /// Nothing was written, for this reason.
        case skipped(String)
    }

    /// Claude Code's config file, as Claude Code names it. The lock is this
    /// path plus `.lock`, also when the path is a link.
    let configFileURL: URL
    /// How long to wait before each further try for the lock. Claude Code
    /// holds it for one read and one write.
    var lockWaits: [Duration] = [50, 100, 200, 400, 800, 1600].map { .milliseconds($0) }
    /// Runs under the lock, after the new file is written and before it
    /// replaces the old one. For tests.
    var beforeReplace: (@Sendable () -> Void)?

    static let lockSuffix = ".lock"
    /// A write that takes longer than this gives up before it replaces the
    /// file: the lock may count as left behind soon.
    static let maximumHold: TimeInterval = 5
    private static let maximumAttempts = 3

    // MARK: - Where Claude Code keeps its config

    /// The config file of the Claude Code that `profileArgv` starts, or
    /// `nil` when it cannot be known. `environment` is the environment the
    /// agent's terminal inherits.
    ///
    /// Claude Code uses `$CLAUDE_CONFIG_DIR/.claude.json`, or `.claude.json`
    /// in the home folder. An old install can still use `.config.json` in
    /// its `.claude` folder; which of the two files such an install reads
    /// depends on rules that only Claude Code knows, so it gets no write.
    static func configFileURL(
        profileArgv: [String],
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> URL? {
        guard let assignments = environmentAssignments(inArgv: profileArgv) else { return nil }
        let configDirectory = (assignments["CLAUDE_CONFIG_DIR"] ?? environment["CLAUDE_CONFIG_DIR"])
            .flatMap { $0.isEmpty ? nil : $0 }
        let file: URL
        let legacyFile: URL
        if let configDirectory {
            // Claude Code reads a relative path from its own folder.
            guard configDirectory.hasPrefix("/") else { return nil }
            let directory = URL(filePath: configDirectory, directoryHint: .isDirectory)
            file = directory.appending(path: ".claude.json", directoryHint: .notDirectory)
            legacyFile = directory.appending(path: ".config.json", directoryHint: .notDirectory)
        } else {
            guard let home = homeDirectory(environment: environment) else { return nil }
            let directory = URL(filePath: home, directoryHint: .isDirectory)
            file = directory.appending(path: ".claude.json", directoryHint: .notDirectory)
            legacyFile = directory.appending(path: ".claude/.config.json", directoryHint: .notDirectory)
        }
        if let size = (try? fileManager.attributesOfItem(atPath: legacyFile.path))?[.size] as? NSNumber, size.intValue > 0 {
            return nil
        }
        return file
    }

    /// The variables that a profile such as `env NAME=value claude` sets, or
    /// `nil` when the profile changes the environment in a way this does
    /// not read, such as `env -u NAME`.
    static func environmentAssignments(inArgv argv: [String]) -> [String: String]? {
        guard let executable = argv.first,
              URL(filePath: executable).lastPathComponent == "env" else { return [:] }
        var assignments: [String: String] = [:]
        for argument in argv.dropFirst() {
            guard argument.hasPrefix("-") == false else { return nil }
            guard let separator = argument.firstIndex(of: "="), separator != argument.startIndex else { break }
            assignments[String(argument[..<separator])] = String(argument[argument.index(after: separator)...])
        }
        return assignments
    }

    /// The home folder as Claude Code finds it: `HOME`, else the account's.
    private static func homeDirectory(environment: [String: String]) -> String? {
        if let home = environment["HOME"], home.isEmpty == false { return home }
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        return String(cString: directory)
    }

    /// The key Claude Code files a folder under: its path without links, in
    /// Unicode form NFC. `nil` when the folder does not exist.
    static func folderKey(for folder: URL) -> String? {
        guard let resolved = realpath(folder.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved).precomposedStringWithCanonicalMapping
    }

    // MARK: - Trust

    /// Names `folder` as trusted in the config file. Returns what happened;
    /// it never throws, because a start of the agent does not depend on it.
    func trust(folder: URL) async -> Outcome {
        // A link in the folder's place leads to a folder that Toastty did
        // not make. Whether to trust that one is the user's decision.
        var info = stat()
        guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              let key = Self.folderKey(for: folder) else {
            return .skipped("\(folder.path) is not a folder of its own")
        }
        // Without the lock first: a file that names the folder already
        // needs no write and no wait. The rename makes each read whole.
        switch readEdit(key: key) {
        case .success(.alreadyTrusted):
            return .alreadyTrusted
        case .failure(let failure):
            return .skipped(failure.reason)
        case .success(.edited):
            break
        }
        let lockPath = configFileURL.path + Self.lockSuffix
        guard await acquireLock(at: lockPath) else {
            return .skipped("another process holds the lock of \(configFileURL.path)")
        }
        defer { rmdir(lockPath) }
        return writeUnderLock(key: key, lockedAt: Date())
    }

    private func acquireLock(at path: String) async -> Bool {
        var waits = lockWaits[...]
        while true {
            if mkdir(path, 0o777) == 0 { return true }
            // Only a lock that someone holds is worth a wait. A lock that
            // was left behind is Claude Code's to remove.
            guard errno == EEXIST, let wait = waits.popFirst() else { return false }
            do {
                try await Task.sleep(for: wait * Double.random(in: 1 ... 1.5))
            } catch {
                return false
            }
        }
    }

    /// What the file needs, read now. It takes no lock and writes nothing.
    private func readEdit(key: String) -> Result<ClaudeConfigTrustEdit.Result, ClaudeConfigTrustEdit.Failure> {
        readFile().flatMap { file in edit(file.data, key: key) }
    }

    private func edit(_ data: Data, key: String) -> Result<ClaudeConfigTrustEdit.Result, ClaudeConfigTrustEdit.Failure> {
        do {
            return .success(try ClaudeConfigTrustEdit.trusting(folderKey: key, in: data))
        } catch let failure as ClaudeConfigTrustEdit.Failure {
            return .failure(failure)
        } catch {
            return .failure(.init(reason: error.localizedDescription))
        }
    }

    private struct ReadFile {
        /// The file itself, when the config path is a link to it.
        var path: String
        var data: Data
        var identity: Identity
        var permissions: mode_t
    }

    /// What tells one version of the file from the next.
    private struct Identity: Equatable {
        var inode: ino_t
        var size: off_t
        var modified: timespec

        init(_ info: stat) {
            inode = info.st_ino
            size = info.st_size
            modified = info.st_mtimespec
        }

        static func == (left: Identity, right: Identity) -> Bool {
            left.inode == right.inode && left.size == right.size
                && left.modified.tv_sec == right.modified.tv_sec && left.modified.tv_nsec == right.modified.tv_nsec
        }
    }

    private func readFile() -> Result<ReadFile, ClaudeConfigTrustEdit.Failure> {
        // A config file that is a link stays a link: the write replaces
        // the file it points to.
        guard let resolved = realpath(configFileURL.path, nil) else {
            return .failure(.init(reason: errno == ENOENT
                ? "Claude Code has no config file at \(configFileURL.path) yet"
                : "\(configFileURL.path) cannot be read: \(String(cString: strerror(errno)))"))
        }
        defer { free(resolved) }
        let path = String(cString: resolved)
        var before = stat()
        guard stat(path, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.init(reason: "\(path) is not a file"))
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .failure(.init(reason: "\(path) cannot be read"))
        }
        // The same file before and after the read, so the text is one
        // version of it.
        var after = stat()
        guard stat(path, &after) == 0, Identity(after) == Identity(before) else {
            return .failure(.init(reason: "\(path) changed while it was read"))
        }
        return .success(ReadFile(path: path, data: data, identity: Identity(after), permissions: after.st_mode & 0o7777))
    }

    private func writeUnderLock(key: String, lockedAt: Date) -> Outcome {
        var lastReason = "the config file kept changing"
        for _ in 0 ..< Self.maximumAttempts {
            let file: ReadFile
            switch readFile() {
            case .success(let read): file = read
            case .failure(let failure): return .skipped(failure.reason)
            }
            let edited: Data
            switch edit(file.data, key: key) {
            case .success(.alreadyTrusted): return .alreadyTrusted
            case .success(.edited(let data)): edited = data
            case .failure(let failure): return .skipped(failure.reason)
            }
            let temporaryPath = "\(file.path).toastty-\(getpid())-\(UUID().uuidString.prefix(8)).tmp"
            guard Self.writeNewFile(edited, at: temporaryPath, permissions: file.permissions) else {
                unlink(temporaryPath)
                return .skipped("a file beside \(file.path) cannot be written")
            }
            beforeReplace?()
            // A writer that takes no lock may have replaced the file since
            // the read. Its version is then the one to change.
            var now = stat()
            guard stat(file.path, &now) == 0, Identity(now) == file.identity else {
                unlink(temporaryPath)
                lastReason = "\(file.path) changed during the write"
                continue
            }
            guard Date().timeIntervalSince(lockedAt) < Self.maximumHold else {
                unlink(temporaryPath)
                return .skipped("the write took too long to keep the lock")
            }
            guard rename(temporaryPath, file.path) == 0 else {
                let reason = String(cString: strerror(errno))
                unlink(temporaryPath)
                return .skipped("\(file.path) cannot be replaced: \(reason)")
            }
            return .trusted
        }
        return .skipped(lastReason)
    }

    /// Writes all of `data` to a new file and makes sure it is on disk
    /// before a rename can put it in place of the config file.
    private static func writeNewFile(_ data: Data, at path: String, permissions: mode_t) -> Bool {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, permissions)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // `open` applies the process's mask to the permissions.
        guard fchmod(descriptor, permissions) == 0 else { return false }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        return written && fsync(descriptor) == 0
    }
}

extension ClaudeFolderTrust {
    /// Trusts the coordinator's folder for the agent that `profileID`
    /// starts, when that agent is Claude Code. Any other agent has no such
    /// dialog that Toastty knows of.
    static func trustCoordinatorFolder(
        _ directory: String,
        profileID: String,
        profileArgv: [String],
        environment: [String: String]
    ) async {
        guard AgentKind(rawValue: profileID) == .claude else { return }
        guard let configFileURL = configFileURL(profileArgv: profileArgv, environment: environment) else {
            ToasttyLog.info("Left Claude Code's folder trust alone", category: .tasks, metadata: [
                "reason": "Toastty cannot tell which config file this Claude Code uses",
            ])
            return
        }
        let trust = ClaudeFolderTrust(configFileURL: configFileURL)
        let folder = URL(filePath: directory, directoryHint: .isDirectory)
        // File work, off the main actor.
        let outcome = await Task.detached { await trust.trust(folder: folder) }.value
        switch outcome {
        case .trusted:
            ToasttyLog.info("Told Claude Code that the coordinator's folder is trusted", category: .tasks, metadata: [
                "config": configFileURL.path, "folder": directory,
            ])
        case .alreadyTrusted:
            break
        case .skipped(let reason):
            ToasttyLog.warning("Could not tell Claude Code that the coordinator's folder is trusted", category: .tasks, metadata: [
                "config": configFileURL.path, "folder": directory, "reason": reason,
            ])
        }
    }
}
