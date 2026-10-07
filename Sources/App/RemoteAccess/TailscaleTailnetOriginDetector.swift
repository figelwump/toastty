import Darwin
import Foundation

enum TailscaleTailnetOriginDetectionError: Error, Equatable, Sendable {
    case notInstalled
    case needsLogin
    case needsMachineApproval
    case notRunning
    case invalidOrigin
    case timedOut
    case unavailable

    var recoveryMessage: String {
        switch self {
        case .notInstalled:
            "Tailscale couldn’t be found. Open Tailscale or enter the origin manually."
        case .needsLogin:
            "Sign in to Tailscale, then try detecting again."
        case .needsMachineApproval:
            "Approve this Mac in the Tailscale admin console, then try detecting again."
        case .notRunning:
            "Connect Tailscale, then try detecting again."
        case .invalidOrigin:
            "Tailscale returned a hostname Toastty can’t use. Enter the .ts.net origin manually."
        case .timedOut:
            "Tailscale didn’t respond. Try again or enter the origin manually."
        case .unavailable:
            "Toastty couldn’t detect the Tailnet origin. Enter it manually."
        }
    }
}

struct TailscaleTailnetOriginDetector: Sendable {
    typealias CommandRunner = @Sendable (URL, [String], TimeInterval) async throws -> Data
    typealias ExecutableCheck = @Sendable (URL) -> Bool

    // Prefer the app bundle because a Homebrew client can target a different
    // daemon. The wrappers remain useful for non-app Tailscale installations.
    static var defaultExecutableCandidates: [URL] {
#if DEBUG
        // Isolated GUI validation uses a disposable executable, never the
        // remote host's shared Tailscale configuration. Release ignores this.
        if let path = ProcessInfo.processInfo.environment["TOASTTY_TAILSCALE_CLI_PATH"], path.hasPrefix("/") {
            return [URL(fileURLWithPath: path)]
        }
#endif
        return [
            URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
            URL(fileURLWithPath: "/usr/local/bin/tailscale"),
            URL(fileURLWithPath: "/opt/homebrew/bin/tailscale"),
        ]
    }

    private let executableCandidates: [URL]
    private let timeout: TimeInterval
    private let commandRunner: CommandRunner
    private let isExecutable: ExecutableCheck

    init(
        executableCandidates: [URL] = Self.defaultExecutableCandidates,
        timeout: TimeInterval = 3,
        commandRunner: @escaping CommandRunner = TailscaleStatusCommandRunner.run,
        isExecutable: @escaping ExecutableCheck = Self.defaultExecutableCheck
    ) {
        self.executableCandidates = executableCandidates
        self.timeout = timeout
        self.commandRunner = commandRunner
        self.isExecutable = isExecutable
    }

    func detectOrigin() async throws -> String {
        try await detectClient().origin
    }

    /// Keep setup on the same daemon that supplied the hostname. Falling back
    /// to another executable after a write could change a different profile.
    func detectClient() async throws -> TailscaleClientIdentity {
        let availableCandidates = executableCandidates.filter(isExecutable)
        guard availableCandidates.isEmpty == false else {
            throw TailscaleTailnetOriginDetectionError.notInstalled
        }

        let deadline = Date().addingTimeInterval(timeout)
        var preferredError: TailscaleTailnetOriginDetectionError = .unavailable

        for (index, executableURL) in availableCandidates.enumerated() {
            try Task.checkCancellation()

            let remainingTime = deadline.timeIntervalSinceNow
            guard remainingTime > 0 else {
                throw Self.preferred(.timedOut, over: preferredError)
            }
            let remainingCandidateCount = availableCandidates.count - index
            let attemptTimeout = remainingTime / Double(remainingCandidateCount)
            guard attemptTimeout >= 0.25 else {
                throw Self.preferred(.timedOut, over: preferredError)
            }

            do {
                let data = try await commandRunner(
                    executableURL,
                    // Status is read-only. Toastty never mutates the user's
                    // existing Serve configuration during origin detection.
                    ["status", "--json", "--peers=false"],
                    attemptTimeout
                )
                return try Self.clientIdentity(fromStatusJSON: data, executableURL: executableURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TailscaleTailnetOriginDetectionError {
                preferredError = Self.preferred(error, over: preferredError)
            } catch TailscaleStatusCommandRunnerError.timedOut {
                preferredError = Self.preferred(.timedOut, over: preferredError)
            } catch {
                preferredError = Self.preferred(.unavailable, over: preferredError)
            }
        }

        throw preferredError
    }

    static func origin(fromStatusJSON data: Data) throws -> String {
        try clientIdentity(fromStatusJSON: data, executableURL: URL(fileURLWithPath: "/unused")).origin
    }

    static func clientIdentity(fromStatusJSON data: Data, executableURL: URL) throws -> TailscaleClientIdentity {
        let status: Status
        do {
            status = try JSONDecoder().decode(Status.self, from: data)
        } catch {
            throw TailscaleTailnetOriginDetectionError.unavailable
        }

        guard let backendState = status.backendState?.lowercased() else {
            throw TailscaleTailnetOriginDetectionError.unavailable
        }
        switch backendState {
        case "running":
            break
        case "needslogin":
            throw TailscaleTailnetOriginDetectionError.needsLogin
        case "needsmachineauth":
            throw TailscaleTailnetOriginDetectionError.needsMachineApproval
        default:
            throw TailscaleTailnetOriginDetectionError.notRunning
        }

        guard var dnsName = status.selfNode?.dnsName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            dnsName.isEmpty == false else {
            throw TailscaleTailnetOriginDetectionError.unavailable
        }
        while dnsName.hasSuffix(".") {
            dnsName.removeLast()
        }

        guard let origin = RemoteAccessService.publicGatewayURL(from: dnsName) else {
            throw TailscaleTailnetOriginDetectionError.invalidOrigin
        }
        return TailscaleClientIdentity(executableURL: executableURL, origin: origin.absoluteString, nodeID: status.selfNode?.id)
    }

    private static func defaultExecutableCheck(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func preferred(
        _ candidate: TailscaleTailnetOriginDetectionError,
        over current: TailscaleTailnetOriginDetectionError
    ) -> TailscaleTailnetOriginDetectionError {
        errorPriority(candidate) >= errorPriority(current) ? candidate : current
    }

    private static func errorPriority(_ error: TailscaleTailnetOriginDetectionError) -> Int {
        switch error {
        case .notInstalled: 0
        case .unavailable: 1
        case .timedOut: 2
        case .invalidOrigin: 3
        case .notRunning: 4
        case .needsMachineApproval: 5
        case .needsLogin: 6
        }
    }

    private struct Status: Decodable {
        struct SelfNode: Decodable {
            let dnsName: String?
            let id: String?

            enum CodingKeys: String, CodingKey {
                case dnsName = "DNSName"
                case id = "ID"
            }
        }

        let backendState: String?
        let selfNode: SelfNode?

        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState"
            case selfNode = "Self"
        }
    }
}

struct TailscaleClientIdentity: Equatable, Sendable {
    let executableURL: URL
    let origin: String
    let nodeID: String?
}

struct TailscaleCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    let timedOut: Bool
}

enum TailscaleStatusCommandRunnerError: Error, Equatable, Sendable {
    case timedOut
    case commandFailed(Int32)
    case outputUnavailable
}

enum TailscaleStatusCommandRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Data {
        let result = try await runResult(executableURL: executableURL, arguments: arguments, timeout: timeout)
        if result.timedOut { throw TailscaleStatusCommandRunnerError.timedOut }
        guard result.exitCode == 0 else {
            throw TailscaleStatusCommandRunnerError.commandFailed(result.exitCode)
        }
        return result.stdout
    }

    /// Serve may print an approval URL and wait, or exit zero without changing
    /// anything. The caller needs bounded output even after a timeout/failure.
    static func runResult(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> TailscaleCommandResult {
        let cancellationState = CancellationState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try runBlocking(
                            executableURL: executableURL,
                            arguments: arguments,
                            timeout: timeout,
                            cancellationState: cancellationState
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellationState.cancel()
        }
    }

    private static func runBlocking(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        cancellationState: CancellationState
    ) throws -> TailscaleCommandResult {
        try cancellationState.checkCancellation()
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "toastty-tailscale-status-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.json")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.txt")
        // Files avoid pipe-buffer deadlocks if a future CLI emits more output
        // than expected, while the --peers=false response stays intentionally small.
        guard fileManager.createFile(atPath: stdoutURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]),
              fileManager.createFile(atPath: stderrURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw TailscaleStatusCommandRunnerError.outputUnavailable
        }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let stdoutReader = try FileHandle(forReadingFrom: stdoutURL)
        let stderrReader = try FileHandle(forReadingFrom: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? stdoutReader.close()
            try? stderrReader.close()
        }
        // Keep capture files open but unnamed, so a crash cannot leave raw
        // Tailscale status or approval links behind in the temporary directory.
        try fileManager.removeItem(at: stdoutURL)
        try fileManager.removeItem(at: stderrURL)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        // Tailscale's macOS app and CLI share a binary. Preserve the launch
        // environment while forcing command-line behavior for Finder launches.
        process.environment = environment(merging: ProcessInfo.processInfo.environment)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        process.standardInput = FileHandle.nullDevice

        try cancellationState.checkCancellation()
        try process.run()
        defer {
            if process.isRunning { stop(process) }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        let maximumOutputBytes: UInt64 = 256 * 1_024
        while process.isRunning, clock.now < deadline, cancellationState.isCancelled == false {
            // Stop unbounded output while the child runs, before loading it.
            if try stdoutHandle.offset() > maximumOutputBytes || stderrHandle.offset() > maximumOutputBytes {
                stop(process)
                throw TailscaleStatusCommandRunnerError.outputUnavailable
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        if cancellationState.isCancelled {
            stop(process)
            throw CancellationError()
        }
        let timedOut = process.isRunning
        if timedOut {
            stop(process)
        }

        process.waitUntilExit()

        guard try stdoutHandle.offset() <= maximumOutputBytes,
              try stderrHandle.offset() <= maximumOutputBytes else {
            throw TailscaleStatusCommandRunnerError.outputUnavailable
        }
        return TailscaleCommandResult(
            stdout: try stdoutReader.readToEnd() ?? Data(),
            stderr: try stderrReader.readToEnd() ?? Data(),
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }

    private static func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        let clock = ContinuousClock()
        let terminateDeadline = clock.now.advanced(by: .milliseconds(100))
        while process.isRunning, clock.now < terminateDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    static func environment(merging parentEnvironment: [String: String]) -> [String: String] {
        var environment = parentEnvironment
        environment["TAILSCALE_BE_CLI"] = "1"
        return environment
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func checkCancellation() throws {
            if isCancelled {
                throw CancellationError()
            }
        }
    }
}

enum TailnetOriginDetectionPolicy {
    static func shouldApply(
        originAtStart: String,
        currentOrigin: String,
        allowsReplacingExistingOrigin: Bool
    ) -> Bool {
        guard currentOrigin == originAtStart else { return false }
        return allowsReplacingExistingOrigin
            || originAtStart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
