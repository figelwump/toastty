import Darwin
import Foundation

/// What to run for one Claude Code process that the host talks to in
/// stream-json: the command, its arguments and its environment. Made from the
/// same launch plan that a terminal launch types, so the process gets the
/// same settings, hooks, skills, model and working directory.
public struct ClaudeStreamLaunch: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String

    public enum LaunchError: Error, Equatable, LocalizedError {
        case emptyCommand
        /// The profile's arguments ask for a mode that cannot hold the
        /// coordinator's conversation.
        case unsupportedArgument(String)

        public var errorDescription: String? {
            switch self {
            case .emptyCommand:
                "The agent profile has no command."
            case .unsupportedArgument(let argument):
                "The agent profile passes \(argument) to Claude Code. A session that Toastty runs without a terminal cannot use it: "
                    + "it needs the Claude plan sign-in, hooks and skills, and its own input and output format."
            }
        }
    }

    /// The arguments that put Claude Code in print mode with one JSON object
    /// on each line, in both directions. `--replay-user-messages` makes
    /// Claude write each message of the host back when it takes it.
    /// `--permission-prompt-tool stdio` sends each permission request to the
    /// host and waits for the answer.
    public static let streamArguments = [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--replay-user-messages",
        "--permission-prompt-tool", "stdio",
    ]

    /// Arguments of a profile that this launch cannot keep. `--bare` reads
    /// no plan sign-in, hooks or skills. The others change the format of
    /// the lines or name a different conversation.
    static let refusedArguments: Set<String> = [
        "--bare", "--safe-mode", "-p", "--print", "--input-format", "--output-format",
        "--permission-prompt-tool", "--permission-prompts", "--no-session-persistence",
        "--resume", "-r", "--continue", "-c", "--session-id", "--bg", "--background",
    ]

    /// Variables that mark a process as started inside another Claude Code
    /// session. The app has them only when a developer started it from one.
    static let nestedSessionKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_CHILD_NOTES_DIR", "CLAUDE_PID",
    ]

    /// Variables that make Claude Code bill an API key. In print mode a key
    /// in the environment wins over the plan sign-in.
    public static let apiKeyKeys: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

    /// - Parameters:
    ///   - plannedArguments: the launch plan's `argv`: the profile's command
    ///     with the settings, plugin, model and effort arguments in place.
    ///   - resumeNativeSessionID: Claude's ID of the conversation to go on
    ///     with, or `nil` for a new one.
    ///   - baseEnvironment: the app's own environment.
    ///   - terminalEnvironment: what a terminal of the panel gets on top of
    ///     that: Toastty's socket, CLI and `PATH`.
    ///   - plannedEnvironment: the launch plan's environment.
    public static func make(
        plannedArguments: [String],
        resumeNativeSessionID: String?,
        baseEnvironment: [String: String],
        terminalEnvironment: [String: String],
        plannedEnvironment: [String: String],
        directory: String
    ) throws -> ClaudeStreamLaunch {
        guard plannedArguments.isEmpty == false else { throw LaunchError.emptyCommand }
        let commandIndex = ManagedAgentCommandResolver.launchInsertionIndex(for: .claude, argv: plannedArguments)
        let options = plannedArguments.dropFirst(commandIndex + 1).prefix { $0 != "--" }
        for option in options {
            let name = option.split(separator: "=", maxSplits: 1).first.map(String.init) ?? option
            if refusedArguments.contains(name) {
                throw LaunchError.unsupportedArgument(name)
            }
        }
        var arguments = plannedArguments
        var inserted = streamArguments
        if let resumeNativeSessionID {
            inserted += ["--resume", resumeNativeSessionID]
        }
        arguments.insert(contentsOf: inserted, at: commandIndex + 1)

        var environment = baseEnvironment.filter { key, _ in
            nestedSessionKeys.contains(key) == false && apiKeyKeys.contains(key) == false
        }
        environment.merge(terminalEnvironment) { _, new in new }
        environment.merge(plannedEnvironment) { _, new in new }
        for key in apiKeyKeys {
            environment.removeValue(forKey: key)
        }
        // The command is found on PATH, where Toastty's own launcher for
        // agent commands comes first. This launch is already planned.
        environment[ToasttyLaunchContextEnvironment.managedAgentShimBypassKey] = "1"
        return ClaudeStreamLaunch(
            executablePath: "/usr/bin/env",
            arguments: arguments,
            environment: environment,
            directory: directory
        )
    }
}

/// Runs one process and exchanges lines with it: each line that the process
/// writes to its standard output comes to `onEvent`, and `write` gives it one
/// line on its standard input. The end of the process comes last, once, with
/// the end of what it wrote to its standard error.
///
/// `onEvent` runs on a private queue, in the order of the output.
public final class ClaudeStreamProcess: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        case line(String)
        case exited(status: Int32, errorOutput: String)
    }

    private let launch: ClaudeStreamLaunch
    private let onEvent: @Sendable (Event) -> Void
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let eventQueue = DispatchQueue(label: "toastty.claude-stream.events")
    private let writeQueue = DispatchQueue(label: "toastty.claude-stream.input")
    private let lock = NSLock()
    private var isRunning = false
    private var pendingOutput = Data()
    private var errorOutput = Data()
    private var outputEnded = false
    private var errorEnded = false
    private var exitStatus: Int32?
    private var didReportExit = false

    private static let errorOutputLimit = 16 * 1024
    /// A line longer than this is not a message that this host reads. It is
    /// dropped, so that a broken process cannot fill the app's memory.
    private static let lineLimit = 32 * 1024 * 1024

    public init(launch: ClaudeStreamLaunch, onEvent: @escaping @Sendable (Event) -> Void) {
        self.launch = launch
        self.onEvent = onEvent
    }

    public var processIdentifier: Int32? {
        lock.withLock { isRunning ? process.processIdentifier : nil }
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
        try process.run()
        lock.withLock { isRunning = true }
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

    /// Ends the process: its input closes, which ends Claude Code after the
    /// work it has in hand, and SIGTERM follows for a process that is still
    /// there after `gracePeriod`.
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
    /// Claude Code leaves its turn unfinished and exits.
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
        lock.withLock { isRunning = false }
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
