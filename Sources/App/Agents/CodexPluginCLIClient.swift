import Darwin
import Foundation

struct CodexPluginMarketplace: Equatable, Sendable {
    let name: String
    let rootPath: String
    let sourcePath: String?
}

struct CodexInstalledPlugin: Equatable, Sendable {
    let pluginID: String
    let name: String
    let marketplaceName: String
    let version: String
    let sourcePath: String?
    let marketplaceSourcePath: String?
}

struct CodexPluginInstallation: Equatable, Sendable {
    let pluginID: String
    let name: String
    let marketplaceName: String
    let version: String
    let installedPath: String
}

protocol CodexPluginCLIManaging: Sendable {
    func listMarketplaces(runtime: CodexIntegrationRuntime, deadline: Date) throws -> [CodexPluginMarketplace]
    func listInstalledPlugins(runtime: CodexIntegrationRuntime, deadline: Date) throws -> [CodexInstalledPlugin]
    func addMarketplace(
        runtime: CodexIntegrationRuntime,
        sourcePath: String,
        deadline: Date
    ) throws -> String
    func installPlugin(
        runtime: CodexIntegrationRuntime,
        selector: String,
        deadline: Date
    ) throws -> CodexPluginInstallation
    func removePlugin(
        runtime: CodexIntegrationRuntime,
        selector: String,
        deadline: Date
    ) throws
    func removeMarketplace(
        runtime: CodexIntegrationRuntime,
        name: String,
        deadline: Date
    ) throws
}

struct CodexPluginCLIClient: CodexPluginCLIManaging, @unchecked Sendable {
    private let executor: any CodexPluginCLIExecuting

    init(executor: any CodexPluginCLIExecuting = CodexPluginCLIProcessExecutor()) {
        self.executor = executor
    }

    func listMarketplaces(
        runtime: CodexIntegrationRuntime,
        deadline: Date
    ) throws -> [CodexPluginMarketplace] {
        let response: MarketplaceListResponse = try executeJSON(
            runtime: runtime,
            arguments: ["plugin", "marketplace", "list", "--json"],
            deadline: deadline
        )
        return response.marketplaces.map {
            CodexPluginMarketplace(
                name: $0.name,
                rootPath: $0.root,
                sourcePath: $0.marketplaceSource?.source
            )
        }
    }

    func listInstalledPlugins(
        runtime: CodexIntegrationRuntime,
        deadline: Date
    ) throws -> [CodexInstalledPlugin] {
        let response: PluginListResponse = try executeJSON(
            runtime: runtime,
            arguments: ["plugin", "list", "--json"],
            deadline: deadline
        )
        return response.installed.map {
            CodexInstalledPlugin(
                pluginID: $0.pluginId,
                name: $0.name,
                marketplaceName: $0.marketplaceName,
                version: $0.version,
                sourcePath: $0.source?.path,
                marketplaceSourcePath: $0.marketplaceSource?.source
            )
        }
    }

    func addMarketplace(
        runtime: CodexIntegrationRuntime,
        sourcePath: String,
        deadline: Date
    ) throws -> String {
        let response: MarketplaceAddResponse = try executeJSON(
            runtime: runtime,
            arguments: ["plugin", "marketplace", "add", sourcePath, "--json"],
            deadline: deadline
        )
        return response.marketplaceName
    }

    func installPlugin(
        runtime: CodexIntegrationRuntime,
        selector: String,
        deadline: Date
    ) throws -> CodexPluginInstallation {
        let response: PluginInstallResponse = try executeJSON(
            runtime: runtime,
            arguments: ["plugin", "add", selector, "--json"],
            deadline: deadline
        )
        return CodexPluginInstallation(
            pluginID: response.pluginId,
            name: response.name,
            marketplaceName: response.marketplaceName,
            version: response.version,
            installedPath: response.installedPath
        )
    }

    func removePlugin(
        runtime: CodexIntegrationRuntime,
        selector: String,
        deadline: Date
    ) throws {
        _ = try executor.execute(
            runtime: runtime,
            arguments: ["plugin", "remove", selector, "--json"],
            deadline: deadline
        )
    }

    func removeMarketplace(
        runtime: CodexIntegrationRuntime,
        name: String,
        deadline: Date
    ) throws {
        _ = try executor.execute(
            runtime: runtime,
            arguments: ["plugin", "marketplace", "remove", name, "--json"],
            deadline: deadline
        )
    }
}

private extension CodexPluginCLIClient {
    struct MarketplaceSource: Decodable {
        let source: String?
    }

    struct MarketplaceEntry: Decodable {
        let name: String
        let root: String
        let marketplaceSource: MarketplaceSource?
    }

    struct MarketplaceListResponse: Decodable {
        let marketplaces: [MarketplaceEntry]
    }

    struct MarketplaceAddResponse: Decodable {
        let marketplaceName: String
    }

    struct PluginSource: Decodable {
        let path: String?
    }

    struct PluginEntry: Decodable {
        let pluginId: String
        let name: String
        let marketplaceName: String
        let version: String
        let source: PluginSource?
        let marketplaceSource: MarketplaceSource?
    }

    struct PluginListResponse: Decodable {
        let installed: [PluginEntry]
    }

    struct PluginInstallResponse: Decodable {
        let pluginId: String
        let name: String
        let marketplaceName: String
        let version: String
        let installedPath: String
    }

    func executeJSON<T: Decodable>(
        runtime: CodexIntegrationRuntime,
        arguments: [String],
        deadline: Date
    ) throws -> T {
        let data = try executor.execute(
            runtime: runtime,
            arguments: arguments,
            deadline: deadline
        )
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CodexPluginCLIError.malformedJSON(arguments.joined(separator: " "))
        }
    }
}

protocol CodexPluginCLIExecuting: Sendable {
    func execute(
        runtime: CodexIntegrationRuntime,
        arguments: [String],
        deadline: Date
    ) throws -> Data
}

struct CodexPluginCLIProcessExecutor: CodexPluginCLIExecuting, @unchecked Sendable {
    private let fileManager: FileManager
    private let baseEnvironment: @Sendable () -> [String: String]

    init(
        fileManager: FileManager = .default,
        baseEnvironment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.fileManager = fileManager
        self.baseEnvironment = baseEnvironment
    }

    func execute(
        runtime: CodexIntegrationRuntime,
        arguments: [String],
        deadline: Date
    ) throws -> Data {
        guard fileManager.isExecutableFile(atPath: runtime.executableURL.path) else {
            throw CodexPluginCLIError.executableUnavailable(runtime.executableURL.path)
        }
        guard deadline.timeIntervalSinceNow > 0 else {
            throw CodexPluginCLIError.timedOut
        }

        let process = Process()
        process.executableURL = runtime.executableURL
        process.arguments = arguments
        process.currentDirectoryURL = runtime.workingDirectoryURL
        process.environment = runtime.processEnvironment.applying(to: baseEnvironment())
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let output = CodexPluginCLIProcessOutput()
        stdoutPipe.fileHandleForReading.readabilityHandler = {
            output.appendStdout($0.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = {
            output.appendStderr($0.availableData)
        }
        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodexPluginCLIError.launchFailed(error.localizedDescription)
        }
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.05)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw CodexPluginCLIError.timedOut
        }
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        output.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        output.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        let (stdout, stderr) = output.snapshot()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.isEmpty ? stdout : stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw CodexPluginCLIError.commandFailed(
                arguments.joined(separator: " "),
                Int(process.terminationStatus),
                message
            )
        }
        return stdout
    }
}

private final class CodexPluginCLIProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func appendStdout(_ data: Data) {
        guard data.isEmpty == false else { return }
        lock.lock()
        stdout.append(data)
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        guard data.isEmpty == false else { return }
        lock.lock()
        stderr.append(data)
        lock.unlock()
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}

enum CodexPluginCLIError: LocalizedError, Equatable {
    case executableUnavailable(String)
    case launchFailed(String)
    case timedOut
    case commandFailed(String, Int, String)
    case malformedJSON(String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable(let path):
            return "Codex is not executable at \(path)."
        case .launchFailed(let message):
            return "Unable to run the Codex plugin command: \(message)"
        case .timedOut:
            return "Codex skills provisioning timed out."
        case .commandFailed(let command, let status, let message):
            return "Codex \(command) exited \(status): \(message)"
        case .malformedJSON(let command):
            return "Codex \(command) returned invalid JSON."
        }
    }

    var isUnsupported: Bool {
        guard case .commandFailed(_, _, let message) = self else { return false }
        let normalized = message.lowercased()
        return normalized.contains("unrecognized subcommand")
            || normalized.contains("unexpected argument 'plugin'")
    }

    var isRuntimeUnavailable: Bool {
        guard case .commandFailed(_, let status, let message) = self,
              status == 126 || status == 127 else {
            return false
        }
        let normalized = message.lowercased()
        return normalized.contains("no such file or directory")
            || normalized.contains("permission denied")
            || normalized.contains("bad interpreter")
            || normalized.contains("exec format error")
    }
}
