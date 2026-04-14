import Darwin
import Foundation

public struct ManagedAgentBasePathResolver {
    struct ProbeOutput {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    public struct ExecutableResolution {
        public let executablePath: String
        public let path: String?

        public init(executablePath: String, path: String?) {
            self.executablePath = executablePath
            self.path = path
        }
    }

    typealias LoginShellPathProvider = @Sendable () -> String?
    typealias ShellCommandRunner = @Sendable (_ shellPath: String, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) -> ProbeOutput?

    private static let startMarker = "__TOASTTY_AGENT_BASE_PATH_START__"
    private static let endMarker = "__TOASTTY_AGENT_BASE_PATH_END__"
    private static let executableStartMarker = "__TOASTTY_AGENT_EXECUTABLE_PATH_START__"
    private static let executableEndMarker = "__TOASTTY_AGENT_EXECUTABLE_PATH_END__"

    let environment: [String: String]
    let fallbackPath: String?
    let timeout: TimeInterval
    let loginShellPathProvider: LoginShellPathProvider
    let shellCommandRunner: ShellCommandRunner

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackPath: String? = ProcessInfo.processInfo.environment["PATH"],
        timeout: TimeInterval = 3
    ) {
        self.init(
            environment: environment,
            fallbackPath: fallbackPath,
            timeout: timeout,
            loginShellPathProvider: Self.loginShellPath,
            shellCommandRunner: Self.runShellCommand
        )
    }

    init(
        environment: [String: String],
        fallbackPath: String?,
        timeout: TimeInterval,
        loginShellPathProvider: @escaping LoginShellPathProvider,
        shellCommandRunner: @escaping ShellCommandRunner
    ) {
        self.environment = environment
        self.fallbackPath = fallbackPath
        self.timeout = timeout
        self.loginShellPathProvider = loginShellPathProvider
        self.shellCommandRunner = shellCommandRunner
    }

    public func resolve() -> String? {
        guard let shellPath = loginShellPathProvider(),
              let arguments = Self.probeArguments(forShellPath: shellPath),
              let output = shellCommandRunner(
                  shellPath,
                  arguments,
                  Self.sanitizedEnvironment(from: environment),
                  timeout
              ),
              let resolvedPath = Self.extractedPath(from: output.stdout) else {
            return fallbackPath
        }

        return resolvedPath
    }

    public func resolveExecutable(commandName: String) -> ExecutableResolution? {
        guard let shellPath = loginShellPathProvider(),
              let arguments = Self.executableProbeArguments(
                  forShellPath: shellPath,
                  commandName: commandName
              ),
              let output = shellCommandRunner(
                  shellPath,
                  arguments,
                  Self.sanitizedEnvironment(from: environment),
                  timeout
              ),
              let executablePath = Self.extractedExecutablePath(from: output.stdout) else {
            return nil
        }

        return ExecutableResolution(
            executablePath: executablePath,
            path: Self.extractedPath(from: output.stdout)
        )
    }

    static func probeArguments(forShellPath shellPath: String) -> [String]? {
        let probeScript: String
        let shellName = normalizedShellName(from: shellPath)

        switch shellName {
        case "fish":
            probeScript = "printf '%s' '\(startMarker)'; string join ':' $PATH; printf '%s' '\(endMarker)'"
            return ["-ilc", probeScript]
        case "bash", "zsh":
            probeScript = "printf '%s' '\(startMarker)'; printf '%s' \"$PATH\"; printf '%s' '\(endMarker)'"
            return ["-ilc", probeScript]
        default:
            probeScript = "printf '%s' '\(startMarker)'; printf '%s' \"$PATH\"; printf '%s' '\(endMarker)'"
            return ["-lc", probeScript]
        }
    }

    static func executableProbeArguments(
        forShellPath shellPath: String,
        commandName: String
    ) -> [String]? {
        let shellName = normalizedShellName(from: shellPath)
        let quotedCommandName = shellSingleQuoted(commandName)
        let probeScript: String

        switch shellName {
        case "fish":
            probeScript = """
            printf '%s' '\(startMarker)'; string join ':' $PATH; printf '%s' '\(endMarker)'; set -l resolved (command -v \(quotedCommandName) 2>/dev/null); if test -n "$resolved"; printf '%s' '\(executableStartMarker)'; printf '%s' "$resolved"; printf '%s' '\(executableEndMarker)'; end
            """
            return ["-ilc", probeScript]
        case "bash", "zsh":
            probeScript = """
            printf '%s' '\(startMarker)'; printf '%s' "$PATH"; printf '%s' '\(endMarker)'; resolved=$(command -v \(quotedCommandName) 2>/dev/null || true); if [ -n "$resolved" ]; then printf '%s' '\(executableStartMarker)'; printf '%s' "$resolved"; printf '%s' '\(executableEndMarker)'; fi
            """
            return ["-ilc", probeScript]
        default:
            probeScript = """
            printf '%s' '\(startMarker)'; printf '%s' "$PATH"; printf '%s' '\(endMarker)'; resolved=$(command -v \(quotedCommandName) 2>/dev/null || true); if [ -n "$resolved" ]; then printf '%s' '\(executableStartMarker)'; printf '%s' "$resolved"; printf '%s' '\(executableEndMarker)'; fi
            """
            return ["-lc", probeScript]
        }
    }

    static func extractedPath(from output: String) -> String? {
        let path = extractedValue(
            from: output,
            startMarker: startMarker,
            endMarker: endMarker
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = path
            .split(separator: ":")
            .map(String.init)
            .filter { $0.isEmpty == false }
            .joined(separator: ":")
        return normalizedPath.isEmpty ? nil : normalizedPath
    }

    static func extractedExecutablePath(from output: String) -> String? {
        let rawExecutablePath = extractedValue(
            from: output,
            startMarker: executableStartMarker,
            endMarker: executableEndMarker
        )
        let firstLine = rawExecutablePath
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let firstLine,
              firstLine.isEmpty == false,
              firstLine.hasPrefix("/") else {
            return nil
        }

        return firstLine
    }

    static func sanitizedEnvironment(from environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            key.hasPrefix("TOASTTY_") == false
        }
    }

    static func loginShellPath() -> String? {
        guard let passwdEntry = getpwuid(getuid()),
              let shellPointer = passwdEntry.pointee.pw_shell else {
            return nil
        }

        let shellPath = String(cString: shellPointer)
        return shellPath.isEmpty ? nil : shellPath
    }

    private static func normalizedShellName(from shellPath: String) -> String {
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        return shellName.hasPrefix("-")
            ? String(shellName.dropFirst()).lowercased()
            : shellName.lowercased()
    }

    private static func extractedValue(
        from output: String,
        startMarker: String,
        endMarker: String
    ) -> String {
        guard let startRange = output.range(of: startMarker),
              let endRange = output.range(
                  of: endMarker,
                  range: startRange.upperBound..<output.endIndex
              ) else {
            return ""
        }

        return String(output[startRange.upperBound..<endRange.lowerBound])
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func runShellCommand(
        shellPath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProbeOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exitGroup = DispatchGroup()
        exitGroup.enter()
        process.terminationHandler = { _ in
            exitGroup.leave()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if exitGroup.wait(timeout: .now() + timeout) == .timedOut {
            process.interrupt()
            process.terminate()
            _ = exitGroup.wait(timeout: .now() + 1)
            return nil
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return ProbeOutput(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
