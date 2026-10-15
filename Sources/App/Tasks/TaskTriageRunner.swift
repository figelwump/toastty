import CoreState
import Foundation
import RemoteProtocol

/// The CLI that runs triage. Only Claude and Codex have a headless mode
/// with structured output that Toastty has checked.
enum TaskTriageExecutable: Equatable, Sendable {
    case claude(path: String)
    case codex(path: String)

    /// Accepts the profile's resolved executable only when it is the plain
    /// `claude` or `codex` CLI, not a wrapper whose options Toastty does
    /// not know.
    init?(agent: AgentKind, executablePath: String) {
        let name = URL(filePath: executablePath).lastPathComponent
        switch (agent, name) {
        case (.claude, "claude"): self = .claude(path: executablePath)
        case (.codex, "codex"): self = .codex(path: executablePath)
        default: return nil
        }
    }
}

enum TaskTriageFailure: Error, Equatable, Sendable {
    case timedOut(seconds: Int)
    case cancelled
    case failed(String)
    case unreadableAnswer

    var message: String {
        switch self {
        case .timedOut(let seconds): "Triage did not answer in \(seconds) s."
        case .cancelled: "Triage was stopped."
        case .failed(let detail): "Triage failed: \(detail)"
        case .unreadableAnswer: "Triage gave an answer Toastty could not read."
        }
    }
}

/// Runs one triage call: no tools, no session saved, no hooks, and for
/// Codex none of the user's config, in an empty temporary folder.
struct TaskTriageRunner: Sendable {
    let runner: any TaskCommandRunning
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory

    func run(
        prompt: String,
        executable: TaskTriageExecutable,
        triage: TasksConfig.Triage,
        environment: [String: String]
    ) async -> Result<TaskTriageAnswer, TaskTriageFailure> {
        let directory = temporaryDirectory.appending(path: "toastty-triage-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(.failed("Could not make a temporary folder: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let schemaURL = directory.appending(path: "schema.json")
        let answerURL = directory.appending(path: "answer.json")
        if case .codex = executable {
            do {
                try Data(TaskTriage.outputSchemaJSON.utf8).write(to: schemaURL)
            } catch {
                return .failure(.failed("Could not write the answer schema: \(error.localizedDescription)"))
            }
        }
        let command = Self.command(
            executable: executable,
            triage: triage,
            prompt: prompt,
            directory: directory.path,
            schemaPath: schemaURL.path,
            answerPath: answerURL.path,
            environment: environment
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
            return .failure(.failed("the CLI stopped with signal \(signal)"))
        case .exited(let code):
            do {
                switch executable {
                case .claude:
                    // Claude reports errors such as a missing login in its
                    // JSON result, with a nonzero exit.
                    return .success(try TaskTriage.answer(fromClaudeOutput: result.stdout))
                case .codex:
                    guard code == 0 else { break }
                    return .success(try TaskTriage.answer(fromCodexLastMessage: Data(contentsOf: answerURL)))
                }
            } catch TaskTriageOutputError.providerError(let detail) {
                return .failure(.failed(detail))
            } catch {
                if code == 0 { return .failure(.unreadableAnswer) }
            }
            let detail = TaskCreateScriptOutput.failureDetail(stderr: result.stderrText) ?? "exit status \(code)"
            return .failure(.failed(detail))
        }
    }

    static func command(
        executable: TaskTriageExecutable,
        triage: TasksConfig.Triage,
        prompt: String,
        directory: String,
        schemaPath: String,
        answerPath: String,
        environment: [String: String]
    ) -> TaskCommand {
        switch executable {
        case .claude(let path):
            var arguments = [
                "-p",
                "--output-format", "json",
                "--no-session-persistence",
                "--tools", "",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--settings", #"{"disableAllHooks":true}"#,
                "--json-schema", TaskTriage.outputSchemaJSON,
            ]
            if let model = triage.model { arguments += ["--model", model] }
            if let effort = triage.effort { arguments += ["--effort", effort] }
            return TaskCommand(
                executablePath: path,
                arguments: arguments,
                directory: directory,
                environment: environment,
                standardInput: Data(prompt.utf8),
                timeout: TimeInterval(triage.timeoutSeconds)
            )
        case .codex(let path):
            var arguments = [
                "exec",
                "--skip-git-repo-check",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "-s", "read-only",
                "--color", "never",
                "-C", directory,
                "--output-schema", schemaPath,
                "-o", answerPath,
            ]
            if let model = triage.model { arguments += ["-m", model] }
            if let effort = triage.effort {
                arguments += ["-c", "model_reasoning_effort=\(tomlString(effort))"]
            }
            arguments.append("-")
            return TaskCommand(
                executablePath: path,
                arguments: arguments,
                directory: directory,
                environment: environment,
                standardInput: Data(prompt.utf8),
                timeout: TimeInterval(triage.timeoutSeconds)
            )
        }
    }

    /// A TOML basic string; JSON string escapes are valid TOML escapes.
    private static func tomlString(_ value: String) -> String {
        let encoded = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
        return encoded ?? "\"\""
    }
}
