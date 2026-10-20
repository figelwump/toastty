import CoreState
import Foundation

enum TaskTriageFailure: Error, Equatable, Sendable {
    case timedOut(seconds: Int)
    case cancelled
    case failed(String)

    var message: String {
        switch self {
        case .timedOut(let seconds): "Triage did not answer in \(seconds) s."
        case .cancelled: "Triage was stopped."
        case .failed(let detail): "Triage failed: \(detail)\(detail.hasSuffix(".") ? "" : ".")"
        }
    }
}

/// Runs the triage command once. A protocol so coordinator tests can
/// answer without a process.
protocol TaskTriageRunning: Sendable {
    func run(prompt: String, triage: TasksConfig.Triage) async -> Result<TaskTriage.Answer, TaskTriageFailure>
}

/// Runs `[triage] command` with `/bin/sh -c`, so the user can write it as
/// they would in a terminal. It runs in an empty temporary folder, with
/// the login shell's PATH and without the variables that tie a process to a
/// Toastty session, in its own process group, and is stopped at
/// `timeout_seconds`. The prompt goes to stdin; the answer comes from stdout.
struct TaskLiveTriageRunner: TaskTriageRunning {
    private static let resolvedPath = PathCache()

    var runner: any TaskCommandRunning = TaskLiveCommandRunner()
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory
    /// Replaces the login shell's PATH; tests use it to avoid starting a
    /// login shell.
    var pathOverride: String?

    func run(prompt: String, triage: TasksConfig.Triage) async -> Result<TaskTriage.Answer, TaskTriageFailure> {
        guard let commandLine = triage.command else {
            return .failure(.failed("[triage] has no command"))
        }
        let directory = temporaryDirectory.appending(path: "toastty-triage-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failure(.failed("could not make a temporary folder: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        // Resolving the login PATH starts a shell, so it never runs on the
        // main actor.
        let pathOverride = pathOverride
        let path = await Task.detached(priority: .utility) {
            pathOverride ?? Self.resolvedPath.value()
        }.value
        let command = TaskCommand(
            executablePath: "/bin/sh",
            arguments: ["-c", commandLine],
            directory: directory.path(percentEncoded: false),
            environment: TaskCommandEnvironment.make(path: path),
            standardInput: Data(prompt.utf8),
            timeout: TimeInterval(triage.timeoutSeconds)
        )
        let result = await runner.run(command)

        switch result.termination {
        case .timedOut:
            return .failure(.timedOut(seconds: triage.timeoutSeconds))
        case .cancelled:
            return .failure(.cancelled)
        case .launchFailed(let message):
            return .failure(.failed(message))
        case .signaled(let signal):
            return .failure(.failed("the command stopped with signal \(signal)"))
        case .exited(let code):
            do {
                // An answer counts even with a nonzero exit; `claude -p`
                // reports its own errors in the JSON it prints.
                return .success(try TaskTriage.answer(fromOutput: result.stdout))
            } catch TaskTriage.OutputError.commandError(let detail) {
                return .failure(.failed(detail))
            } catch {
                if code == 0 {
                    return .failure(.failed("the command printed no JSON answer"))
                }
                return .failure(.failed(Self.failureDetail(stderr: result.stderrText) ?? "exit status \(code)"))
            }
        }
    }

    /// The last non-empty line of stderr, which usually says what went
    /// wrong, cut to a length the Inbox can show.
    static func failureDetail(stderr: String) -> String? {
        stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.isEmpty == false }
            .map { String($0.prefix(200)) }
    }

    /// Resolving the login shell's PATH starts a shell, so it runs once.
    private final class PathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false
        private var path: String?

        func value() -> String? {
            lock.withLock {
                if resolved == false {
                    path = ManagedAgentBasePathResolver().resolve()
                    resolved = true
                }
                return path
            }
        }
    }
}
