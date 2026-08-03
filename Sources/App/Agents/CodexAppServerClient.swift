import CoreFoundation
import Darwin
import Foundation

enum CodexAppServerClientError: LocalizedError, Equatable {
    case executableUnavailable(String)
    case launchFailed(String)
    case timedOut
    case serverExited(String)
    case malformedResponse(String)
    case rpcError(method: String, code: Int?, message: String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable(let path):
            return "Codex is not executable at \(path)."
        case .launchFailed(let message):
            return "Unable to start the Codex app-server: \(message)"
        case .timedOut:
            return "Codex skills configuration timed out."
        case .serverExited(let message):
            return "Codex app-server exited before completing the request: \(message)"
        case .malformedResponse(let method):
            return "Codex app-server returned a malformed response for \(method)."
        case .rpcError(let method, _, let message):
            return "Codex app-server rejected \(method): \(message)"
        }
    }

    var isUnsupported: Bool {
        if case .rpcError(_, let code, _) = self {
            return code == -32601
        }
        return false
    }
}

struct CodexAppServerInvocation: Equatable, Sendable {
    let executableURL: URL
    let codexHomeURL: URL
    let workingDirectoryURL: URL
    let configOverrides: [String]
    let timeout: TimeInterval
}

struct CodexSkillState: Equatable, Sendable {
    let name: String
    let enabled: Bool
}

struct CodexAppServerRPCRequest: Equatable, Sendable {
    let method: String
    let params: [String: CodexJSONValue]
}

struct CodexAppServerRPCResponse: Equatable, Sendable {
    let result: CodexJSONValue?
    let errorCode: Int?
    let errorMessage: String?
}

indirect enum CodexJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([CodexJSONValue])
    case object([String: CodexJSONValue])

    init?(jsonObject: Any) {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if value.doubleValue.rounded() == value.doubleValue {
                self = .int(value.intValue)
            } else {
                self = .double(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let values as [Any]:
            var converted: [CodexJSONValue] = []
            for value in values {
                guard let item = CodexJSONValue(jsonObject: value) else { return nil }
                converted.append(item)
            }
            self = .array(converted)
        case let values as [String: Any]:
            var converted: [String: CodexJSONValue] = [:]
            for (key, value) in values {
                guard let item = CodexJSONValue(jsonObject: value) else { return nil }
                converted[key] = item
            }
            self = .object(converted)
        default:
            return nil
        }
    }

    var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.jsonObject)
        case .object(let values): return values.mapValues(\.jsonObject)
        }
    }

    var objectValue: [String: CodexJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [CodexJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

protocol CodexAppServerRPCTransporting: Sendable {
    func perform(
        invocation: CodexAppServerInvocation,
        requests: [CodexAppServerRPCRequest]
    ) throws -> [CodexAppServerRPCResponse]
}

struct CodexAppServerProcessTransport: CodexAppServerRPCTransporting, @unchecked Sendable {
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

    func perform(
        invocation: CodexAppServerInvocation,
        requests: [CodexAppServerRPCRequest]
    ) throws -> [CodexAppServerRPCResponse] {
        guard fileManager.isExecutableFile(atPath: invocation.executableURL.path) else {
            throw CodexAppServerClientError.executableUnavailable(invocation.executableURL.path)
        }
        guard invocation.timeout > 0 else {
            throw CodexAppServerClientError.timedOut
        }

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.configOverrides.flatMap { ["-c", $0] }
            + ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = invocation.workingDirectoryURL
        var environment = baseEnvironment()
        environment["CODEX_HOME"] = invocation.codexHomeURL.path
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = CodexAppServerProcessState()
        stdoutPipe.fileHandleForReading.readabilityHandler = { state.consume($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { state.consumeStderr($0.availableData) }
        process.terminationHandler = { state.recordExit(status: $0.terminationStatus) }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerClientError.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(invocation.timeout)
        defer {
            stdinPipe.fileHandleForWriting.closeFile()
            Self.terminateAndReap(process)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        try Self.send(
            method: "initialize",
            id: 1,
            params: [
                "clientInfo": .object([
                    "name": .string("toastty-codex-skills"),
                    "title": .string("Toastty Codex Skills"),
                    "version": .string(
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                    ),
                ]),
                "capabilities": .object(["experimentalApi": .bool(true)]),
            ],
            to: stdinPipe.fileHandleForWriting
        )
        _ = try state.waitForResponse(id: 1, deadline: deadline)
        try Self.sendNotification(method: "initialized", to: stdinPipe.fileHandleForWriting)

        for (offset, request) in requests.enumerated() {
            try Self.send(
                method: request.method,
                id: offset + 2,
                params: request.params,
                to: stdinPipe.fileHandleForWriting
            )
        }

        return try requests.indices.map {
            try state.waitForResponse(id: $0 + 2, deadline: deadline)
        }
    }

    private static func send(
        method: String,
        id: Int,
        params: [String: CodexJSONValue],
        to handle: FileHandle
    ) throws {
        try sendJSONObject(
            ["method": method, "id": id, "params": params.mapValues(\.jsonObject)],
            to: handle
        )
    }

    private static func sendNotification(method: String, to handle: FileHandle) throws {
        try sendJSONObject(["method": method], to: handle)
    }

    private static func sendJSONObject(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func terminateAndReap(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.05)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private final class CodexAppServerProcessState: @unchecked Sendable {
    private let condition = NSCondition()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var responses: [Int: CodexAppServerRPCResponse] = [:]
    private var exitStatus: Int32?

    func consume(_ data: Data) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        guard data.isEmpty == false else { return }
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.prefix(upTo: newline)
            stdoutBuffer.removeSubrange(...newline)
            guard line.isEmpty == false,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let idNumber = object["id"] as? NSNumber else {
                continue
            }
            let result = object["result"].flatMap(CodexJSONValue.init(jsonObject:))
            let error = object["error"] as? [String: Any]
            responses[idNumber.intValue] = CodexAppServerRPCResponse(
                result: result,
                errorCode: (error?["code"] as? NSNumber)?.intValue,
                errorMessage: error?["message"] as? String
            )
        }
    }

    func consumeStderr(_ data: Data) {
        guard data.isEmpty == false else { return }
        condition.lock()
        stderrBuffer.append(data)
        condition.unlock()
    }

    func recordExit(status: Int32) {
        condition.lock()
        exitStatus = status
        condition.broadcast()
        condition.unlock()
    }

    func waitForResponse(id: Int, deadline: Date) throws -> CodexAppServerRPCResponse {
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil, exitStatus == nil, Date() < deadline {
            condition.wait(until: deadline)
        }
        if let response = responses[id] {
            return response
        }
        if exitStatus != nil {
            let message = String(data: stderrBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw CodexAppServerClientError.serverExited(message)
        }
        throw CodexAppServerClientError.timedOut
    }
}

protocol CodexSkillsConfiguring: Sendable {
    func writeSkillConfigs(
        invocation: CodexAppServerInvocation,
        states: [CodexSkillState]
    ) throws
    func listSkills(invocation: CodexAppServerInvocation) throws -> [CodexSkillState]
}

struct CodexAppServerClient: CodexSkillsConfiguring, @unchecked Sendable {
    private let transport: any CodexAppServerRPCTransporting

    init(transport: any CodexAppServerRPCTransporting = CodexAppServerProcessTransport()) {
        self.transport = transport
    }

    func writeSkillConfigs(
        invocation: CodexAppServerInvocation,
        states: [CodexSkillState]
    ) throws {
        let ordered = states.sorted { $0.name < $1.name }
        let responses = try transport.perform(
            invocation: invocation,
            requests: ordered.map {
                CodexAppServerRPCRequest(
                    method: "skills/config/write",
                    params: ["name": .string($0.name), "enabled": .bool($0.enabled)]
                )
            }
        )
        guard responses.count == ordered.count else {
            throw CodexAppServerClientError.malformedResponse("skills/config/write")
        }
        for (state, response) in zip(ordered, responses) {
            let result = try checkedResult(response, method: "skills/config/write")
            guard result.objectValue?["effectiveEnabled"]?.boolValue == state.enabled else {
                throw CodexAppServerClientError.malformedResponse("skills/config/write")
            }
        }
    }

    func listSkills(invocation: CodexAppServerInvocation) throws -> [CodexSkillState] {
        let responses = try transport.perform(
            invocation: invocation,
            requests: [
                CodexAppServerRPCRequest(
                    method: "skills/list",
                    params: [
                        "cwds": .array([.string(invocation.workingDirectoryURL.path)]),
                        "forceReload": .bool(true),
                    ]
                ),
            ]
        )
        guard let response = responses.first else {
            throw CodexAppServerClientError.malformedResponse("skills/list")
        }
        let result = try checkedResult(response, method: "skills/list")
        return (result.objectValue?["data"]?.arrayValue ?? []).flatMap { entry in
            entry.objectValue?["skills"]?.arrayValue ?? []
        }.compactMap { skill in
            guard let object = skill.objectValue,
                  let name = object["name"]?.stringValue,
                  let enabled = object["enabled"]?.boolValue else {
                return nil
            }
            return CodexSkillState(name: name, enabled: enabled)
        }
    }

    private func checkedResult(
        _ response: CodexAppServerRPCResponse,
        method: String
    ) throws -> CodexJSONValue {
        if let message = response.errorMessage {
            throw CodexAppServerClientError.rpcError(
                method: method,
                code: response.errorCode,
                message: message
            )
        }
        guard let result = response.result else {
            throw CodexAppServerClientError.malformedResponse(method)
        }
        return result
    }
}
