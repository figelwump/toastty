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
    static let defaultExecutableCandidates = [
        URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
        URL(fileURLWithPath: "/usr/local/bin/tailscale"),
        URL(fileURLWithPath: "/opt/homebrew/bin/tailscale"),
    ]

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
                return try Self.origin(fromStatusJSON: data)
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
        return origin.absoluteString
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

            enum CodingKeys: String, CodingKey {
                case dnsName = "DNSName"
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
    ) throws -> Data {
        try cancellationState.checkCancellation()
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "toastty-tailscale-status-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.json")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.txt")
        // Files avoid pipe-buffer deadlocks if a future CLI emits more output
        // than expected, while the --peers=false response stays intentionally small.
        guard fileManager.createFile(atPath: stdoutURL.path, contents: Data()),
              fileManager.createFile(atPath: stderrURL.path, contents: Data()) else {
            throw TailscaleStatusCommandRunnerError.outputUnavailable
        }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        // Tailscale's macOS app and CLI share a binary. Preserve the launch
        // environment while forcing command-line behavior for Finder launches.
        process.environment = environment(merging: ProcessInfo.processInfo.environment)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, cancellationState.isCancelled == false {
            Thread.sleep(forTimeInterval: 0.01)
        }

        if cancellationState.isCancelled {
            stop(process)
            throw CancellationError()
        }
        guard process.isRunning == false else {
            stop(process)
            throw TailscaleStatusCommandRunnerError.timedOut
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TailscaleStatusCommandRunnerError.commandFailed(process.terminationStatus)
        }
        return try Data(contentsOf: stdoutURL)
    }

    private static func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        let terminateDeadline = Date().addingTimeInterval(0.1)
        while process.isRunning, Date() < terminateDeadline {
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
