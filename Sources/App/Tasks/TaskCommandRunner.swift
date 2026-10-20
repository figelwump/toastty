import Darwin
import Foundation

/// One run of an external command for a task: git, or the workspace's
/// `create_hook`.
struct TaskCommand: Sendable, Equatable {
    var executablePath: String
    /// Arguments after the executable name.
    var arguments: [String]
    var directory: String
    var environment: [String: String]
    var timeout: TimeInterval
}

struct TaskCommandResult: Sendable, Equatable {
    enum Termination: Sendable, Equatable {
        case exited(Int32)
        case signaled(Int32)
        case timedOut
        case cancelled
        case launchFailed(String)
    }

    var termination: Termination
    var stdout: Data
    var stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

protocol TaskCommandRunning: Sendable {
    func run(_ command: TaskCommand) async -> TaskCommandResult
}

/// Runs a command in a new process group, with stdin from /dev/null, so a
/// timeout or a cancel stops the whole tree it started, not only its first
/// process. A descendant that leaves the group (for example with `setsid`)
/// is not stopped. Only the last `outputLimit` bytes of each stream are
/// kept, so a chatty command can never stall on a full pipe, and a failure
/// at the end of long output stays visible.
struct TaskLiveCommandRunner: TaskCommandRunning {
    var outputLimit = 256 * 1024
    var terminationGracePeriod: TimeInterval = 2
    /// How long to keep reading after the command exits, for output that
    /// descendants still write to the shared pipes.
    var outputDrainGracePeriod: TimeInterval = 1
    /// Where running commands are registered, so quitting can stop them.
    var groups: TaskCommandGroups = .shared

    func run(_ command: TaskCommand) async -> TaskCommandResult {
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let thread = Thread {
                    continuation.resume(returning: runBlocking(command, cancellation: cancellation))
                }
                thread.name = "toastty-task-command"
                thread.qualityOfService = .utility
                thread.start()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func runBlocking(_ command: TaskCommand, cancellation: CancellationFlag) -> TaskCommandResult {
        if cancellation.isCancelled {
            return TaskCommandResult(termination: .cancelled, stdout: Data(), stderr: Data())
        }
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        defer {
            for descriptor in stdoutPipe + stderrPipe where descriptor >= 0 {
                close(descriptor)
            }
        }
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            return launchFailure("Could not create pipes: \(String(cString: strerror(errno)))")
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        if #available(macOS 26.0, *) {
            posix_spawn_file_actions_addchdir(&actions, command.directory)
        } else {
            posix_spawn_file_actions_addchdir_np(&actions, command.directory)
        }
        // A new process group, only the three standard descriptors, and
        // default signal handling (the app ignores SIGPIPE; the child must not).
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = ~sigset_t(0)
        var noSignals = sigset_t(0)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = [command.executablePath] + command.arguments
        let environment = command.environment.map { "\($0.key)=\($0.value)" }
        var processID = pid_t()
        let spawnStatus = withCStringArray(argv) { argvPointers in
            withCStringArray(environment) { environmentPointers in
                posix_spawn(&processID, command.executablePath, &actions, &attributes, argvPointers, environmentPointers)
            }
        }
        guard spawnStatus == 0 else {
            return launchFailure("Could not run \(command.executablePath): \(String(cString: strerror(spawnStatus)))")
        }
        groups.insert(processID)
        defer { groups.remove(processID) }

        // Only the child keeps the write ends of the output pipes, so EOF
        // arrives when the child's tree is done.
        close(stdoutPipe[1]); stdoutPipe[1] = -1
        close(stderrPipe[1]); stderrPipe[1] = -1

        var stdout = BoundedBuffer(limit: outputLimit)
        var stderr = BoundedBuffer(limit: outputLimit)
        var openDescriptors: [Int32: Bool] = [stdoutPipe[0]: true, stderrPipe[0]: true]
        for descriptor in openDescriptors.keys {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }

        let startedAt = Date()
        var waitStatus: Int32 = 0
        var exitedAt: Date?
        var stopReason: TaskCommandResult.Termination?
        var terminateSentAt: Date?
        var killSent = false

        while true {
            if exitedAt == nil, waitpid(processID, &waitStatus, WNOHANG) == processID {
                exitedAt = Date()
            }
            if exitedAt != nil, stopReason != nil {
                // The first process is gone, but a stopped command must not
                // leave anything behind: end the rest of its group now.
                if killSent == false { killpg(processID, SIGKILL) }
                break
            }
            let anyOpen = openDescriptors.values.contains(true)
            if let exitedAt, anyOpen == false || Date().timeIntervalSince(exitedAt) > outputDrainGracePeriod {
                break
            }
            if exitedAt == nil, stopReason == nil {
                if cancellation.isCancelled {
                    stopReason = .cancelled
                } else if Date().timeIntervalSince(startedAt) > command.timeout {
                    stopReason = .timedOut
                }
                if stopReason != nil {
                    killpg(processID, SIGTERM)
                    terminateSentAt = Date()
                }
            }
            if let terminateSentAt, killSent == false, Date().timeIntervalSince(terminateSentAt) > terminationGracePeriod {
                killpg(processID, SIGKILL)
                killSent = true
            }
            if anyOpen {
                Self.readAvailable(from: &openDescriptors, stdoutDescriptor: stdoutPipe[0], stdout: &stdout, stderr: &stderr)
            } else {
                usleep(50_000)
            }
        }
        if exitedAt == nil {
            _ = waitpid(processID, &waitStatus, 0)
        }

        let termination: TaskCommandResult.Termination
        if let stopReason {
            termination = stopReason
        } else if waitStatus & 0x7F == 0 {
            termination = .exited((waitStatus >> 8) & 0xFF)
        } else {
            termination = .signaled(waitStatus & 0x7F)
        }
        return TaskCommandResult(termination: termination, stdout: stdout.tail, stderr: stderr.tail)
    }

    private func launchFailure(_ message: String) -> TaskCommandResult {
        TaskCommandResult(termination: .launchFailed(message), stdout: Data(), stderr: Data())
    }

    /// Waits up to 100 ms for output, then reads what is there. A closed
    /// pipe is marked so the caller stops polling it.
    private static func readAvailable(
        from openDescriptors: inout [Int32: Bool],
        stdoutDescriptor: Int32,
        stdout: inout BoundedBuffer,
        stderr: inout BoundedBuffer
    ) {
        var pollDescriptors = openDescriptors.filter(\.value).keys.map {
            pollfd(fd: $0, events: Int16(POLLIN), revents: 0)
        }
        guard poll(&pollDescriptors, nfds_t(pollDescriptors.count), 100) > 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        for entry in pollDescriptors where entry.revents != 0 {
            while true {
                let count = read(entry.fd, &chunk, chunk.count)
                if count > 0 {
                    if entry.fd == stdoutDescriptor {
                        stdout.append(chunk[0..<count])
                    } else {
                        stderr.append(chunk[0..<count])
                    }
                    continue
                }
                if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    openDescriptors[entry.fd] = false
                }
                break
            }
        }
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    /// Stops every task command still running, for app quit: their process
    /// groups would otherwise outlive Toastty and race a later retry.
    static func stopAllRunningCommands() {
        TaskCommandGroups.shared.stopAll()
    }

    /// The last `limit` bytes appended.
    private struct BoundedBuffer {
        let limit: Int
        var data = Data()

        mutating func append(_ bytes: ArraySlice<UInt8>) {
            data.append(contentsOf: bytes.suffix(limit))
            // Trimmed in batches, so a long stream does not copy on every read.
            if data.count > limit * 2 {
                data = data.suffix(limit)
            }
        }

        var tail: Data { data.suffix(limit) }
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        func cancel() {
            lock.withLock { cancelled = true }
        }
    }
}

/// The environment for task commands: the app's own, without the variables
/// that would tie the command to a Toastty session or panel, and with the
/// login shell's PATH so Homebrew tools and agent CLIs resolve.
enum TaskCommandEnvironment {
    static func make(
        base: [String: String] = ProcessInfo.processInfo.environment,
        path: String?,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var environment = base.filter { $0.key.hasPrefix("TOASTTY_") == false }
        if let path, path.isEmpty == false {
            environment["PATH"] = path
        }
        // Nothing can answer a prompt; fail instead of waiting for one.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment.merge(extra) { _, new in new }
        return environment
    }
}

/// The process groups of running task commands.
final class TaskCommandGroups: @unchecked Sendable {
    static let shared = TaskCommandGroups()

    private let lock = NSLock()
    private var groups = Set<pid_t>()

    func insert(_ group: pid_t) { lock.withLock { _ = groups.insert(group) } }
    func remove(_ group: pid_t) { lock.withLock { _ = groups.remove(group) } }

    /// Sends SIGTERM to every group, then SIGKILL after `gracePeriod`.
    func stopAll(gracePeriod: TimeInterval = 0.3) {
        guard signalAll(SIGTERM) else { return }
        Thread.sleep(forTimeInterval: gracePeriod)
        _ = signalAll(SIGKILL)
    }

    /// Returns whether any group was signaled.
    private func signalAll(_ signal: Int32) -> Bool {
        let current = lock.withLock { groups }
        for group in current { killpg(group, signal) }
        return current.isEmpty == false
    }
}
