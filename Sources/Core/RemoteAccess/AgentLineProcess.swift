import Darwin
import Foundation

/// What to run for one agent process that the host exchanges lines with: the
/// command, its arguments, its environment and its working directory.
public struct AgentProcessLaunch: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String

    public init(executablePath: String, arguments: [String], environment: [String: String], directory: String) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }
}

/// Runs one process and exchanges lines with it: each line that the process
/// writes to its standard output comes to `onEvent`, and `write` gives it one
/// line on its standard input. The end of the process comes last, once, with
/// the end of what it wrote to its standard error.
///
/// `onEvent` runs on a private queue, in the order of the output.
public final class AgentLineProcess: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        case line(String)
        case exited(status: Int32, errorOutput: String)
    }

    private let launch: AgentProcessLaunch
    private let onEvent: @Sendable (Event) -> Void
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let eventQueue = DispatchQueue(label: "toastty.agent-line-process.events")
    private let writeQueue = DispatchQueue(label: "toastty.agent-line-process.input")
    private let lock = NSLock()
    private var isRunning = false
    private var pendingOutput = Data()
    private var errorOutput = Data()
    private var outputEnded = false
    private var errorEnded = false
    private var exitStatus: Int32?
    private var didReportExit = false
    private var orphanGuard: ChildProcessOrphanGuard?

    private static let errorOutputLimit = 16 * 1024
    /// A line longer than this is not a message that this host reads. It is
    /// dropped, so that a broken process cannot fill the app's memory.
    private static let lineLimit = 32 * 1024 * 1024

    public init(launch: AgentProcessLaunch, onEvent: @escaping @Sendable (Event) -> Void) {
        self.launch = launch
        self.onEvent = onEvent
    }

    public var processIdentifier: Int32? {
        lock.withLock { isRunning && process.isRunning ? process.processIdentifier : nil }
    }

    public func start() throws {
        process.executableURL = URL(fileURLWithPath: launch.executablePath)
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = URL(fileURLWithPath: launch.directory, isDirectory: true)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // A write after the process ended gives an error, not a signal that
        // would end the app.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.eventQueue.async { self.receiveOutput(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.eventQueue.async { self.receiveErrorOutput(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            guard let self else { return }
            self.eventQueue.async { self.receiveExit(status) }
        }
        // Before the run: a process that ends at once reports its exit on
        // another queue, and that report must find the state it clears.
        lock.withLock { isRunning = true }
        do {
            try process.run()
        } catch {
            lock.withLock { isRunning = false }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        // A session with no guard still works. `/bin/sh` is always there,
        // so only a system with no room for one more process gets here.
        if let orphanGuard = try? ChildProcessOrphanGuard(childProcessIdentifier: process.processIdentifier) {
            // A process that ended at once has its exit report behind it.
            let processEnded = lock.withLock {
                guard isRunning else { return true }
                self.orphanGuard = orphanGuard
                return false
            }
            if processEnded {
                orphanGuard.release()
            }
        }
    }

    /// Queues one line for the process. False when the process does not
    /// run. True means that the line is on its way, not that the process
    /// read it: the process says so itself, in its output.
    @discardableResult
    public func write(line: String) -> Bool {
        guard lock.withLock({ isRunning }) else { return false }
        let data = Data((line + "\n").utf8)
        writeQueue.async { [self] in
            // The process is gone when this fails. Its exit event says so.
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
        }
        return true
    }

    /// Ends the process: its input closes, which ends the agent (Claude Code
    /// after the work it has in hand, the Codex app-server at once), and
    /// SIGTERM follows for a process that is still there after
    /// `gracePeriod`.
    public func terminate(gracePeriod: TimeInterval = 2) {
        guard lock.withLock({ isRunning }) else { return }
        writeQueue.async { [self] in
            try? inputPipe.fileHandleForWriting.close()
        }
        eventQueue.asyncAfter(deadline: .now() + gracePeriod) { [self] in
            guard lock.withLock({ isRunning }), process.isRunning else { return }
            process.terminate()
        }
    }

    /// Ends the process now with SIGTERM, for the moment the host quits:
    /// the agent leaves its turn unfinished and exits.
    public func terminateNow() {
        guard lock.withLock({ isRunning }), process.isRunning else { return }
        process.terminate()
    }

    // MARK: - On the event queue

    private func receiveOutput(_ data: Data) {
        guard data.isEmpty == false else {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            outputEnded = true
            if pendingOutput.isEmpty == false {
                emitLine(pendingOutput)
                pendingOutput.removeAll()
            }
            reportExitIfComplete()
            return
        }
        pendingOutput.append(data)
        while let newline = pendingOutput.firstIndex(of: 0x0A) {
            emitLine(pendingOutput[pendingOutput.startIndex..<newline])
            pendingOutput.removeSubrange(pendingOutput.startIndex...newline)
        }
        if pendingOutput.count > Self.lineLimit {
            pendingOutput.removeAll()
        }
    }

    private func emitLine(_ bytes: Data) {
        guard bytes.isEmpty == false, let line = String(data: bytes, encoding: .utf8) else { return }
        onEvent(.line(line))
    }

    private func receiveErrorOutput(_ data: Data) {
        guard data.isEmpty == false else {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            errorEnded = true
            reportExitIfComplete()
            return
        }
        errorOutput.append(data)
        if errorOutput.count > Self.errorOutputLimit * 2 {
            errorOutput = errorOutput.suffix(Self.errorOutputLimit)
        }
    }

    private func receiveExit(_ status: Int32) {
        let orphanGuard = lock.withLock {
            isRunning = false
            defer { self.orphanGuard = nil }
            return self.orphanGuard
        }
        orphanGuard?.release()
        exitStatus = status
        reportExitIfComplete()
        // A descendant that keeps the pipes open must not hold the exit
        // back for good.
        eventQueue.asyncAfter(deadline: .now() + 1) { [self] in
            outputEnded = true
            errorEnded = true
            reportExitIfComplete()
        }
    }

    private func reportExitIfComplete() {
        guard let exitStatus, outputEnded, errorEnded, didReportExit == false else { return }
        didReportExit = true
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        let tail = String(decoding: errorOutput.suffix(Self.errorOutputLimit), as: UTF8.self)
        onEvent(.exited(status: exitStatus, errorOutput: tail))
    }
}

/// Ends a child process when the app ends with no chance to end it, as at a
/// crash. Claude Code does not end at the close of its input while a turn
/// runs. Without this, it would go on with the turn with no host to answer
/// its requests, and the next launch of the app would resume the same
/// conversation in a second process. The Codex app-server ends at the close
/// of its input by itself; the guard covers a wrapper command that does not
/// pass that close on.
///
/// A small shell process waits on a pipe whose other end only the app
/// holds. The system closes that end when the app ends, in any way. The
/// shell then reads the end of the pipe and signals the child: SIGTERM, and
/// SIGKILL for a child that is still there 5 seconds later.
final class ChildProcessOrphanGuard: @unchecked Sendable {
    /// `$1` is the child's process ID. A word on the pipe before its end
    /// means that the app released the guard: the child ended.
    static let script = """
    IFS= read -r word
    [ -n "$word" ] && exit 0
    kill -TERM "$1" 2>/dev/null || exit 0
    tries=0
    while [ "$tries" -lt 50 ] && kill -0 "$1" 2>/dev/null; do sleep 0.1; tries=$((tries + 1)); done
    kill -KILL "$1" 2>/dev/null
    exit 0
    """

    private let pipe = Pipe()
    private let process = Process()
    private let lock = NSLock()
    private var isClosed = false

    init(childProcessIdentifier: Int32) throws {
        let hostEnd = pipe.fileHandleForWriting.fileDescriptor
        // No other child of the app may hold this end: the pipe would stay
        // open after the app's end. And a write to a guard that is gone
        // gives an error, not a signal that would end the app.
        _ = fcntl(hostEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(hostEnd, F_SETNOSIGPIPE, 1)
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.script, "toastty-child-guard", String(childProcessIdentifier)]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForReading.close()
    }

    /// The child ended. The guard ends too and signals nothing: the
    /// child's process ID can belong to another process later.
    func release() {
        close(releasing: true)
    }

    /// What the system does at the app's end: it closes the app's end of
    /// the pipe with nothing written. Tests call this in place of a crash.
    func closeAsAtTheAppsEnd() {
        close(releasing: false)
    }

    private func close(releasing: Bool) {
        let wasClosed = lock.withLock {
            defer { isClosed = true }
            return isClosed
        }
        guard wasClosed == false else { return }
        if releasing {
            try? pipe.fileHandleForWriting.write(contentsOf: Data("released\n".utf8))
        }
        try? pipe.fileHandleForWriting.close()
    }
}
