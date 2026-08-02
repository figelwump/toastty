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
            return "Codex integration assessment timed out."
        case .serverExited(let message):
            return "Codex app-server exited before completing the request: \(message)"
        case .malformedResponse(let method):
            return "Codex app-server returned a malformed response for \(method)."
        case .rpcError(let method, _, let message):
            return "Codex app-server rejected \(method): \(message)"
        }
    }
}

struct CodexAppServerInvocation: Equatable, Sendable {
    let executableURL: URL
    let codexHomeURL: URL
    let workingDirectoryURL: URL
    let configOverrides: [String]
    let timeout: TimeInterval
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
            converted.reserveCapacity(values.count)
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

    var intValue: Int? {
        guard case .int(let value) = self else { return nil }
        return value
    }
}

protocol CodexAppServerRPCTransporting {
    func perform(
        invocation: CodexAppServerInvocation,
        requests: [CodexAppServerRPCRequest]
    ) throws -> [CodexAppServerRPCResponse]
}

struct CodexAppServerProcessTransport: CodexAppServerRPCTransporting {
    private let fileManager: FileManager
    private let baseEnvironment: @Sendable () -> [String: String]

    init(
        fileManager: FileManager = .default,
        baseEnvironment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
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
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            state.consume(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            state.consumeStderr(handle.availableData)
        }
        process.terminationHandler = { process in
            state.recordExit(status: process.terminationStatus)
        }

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
                    "name": .string("toastty-codex-integration"),
                    "title": .string("Toastty Codex Integration"),
                    "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"),
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

        return try requests.indices.map { index in
            try state.waitForResponse(id: index + 2, deadline: deadline)
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

struct CodexAppServerClient: @unchecked Sendable {
    private let transport: any CodexAppServerRPCTransporting

    init(transport: any CodexAppServerRPCTransporting = CodexAppServerProcessTransport()) {
        self.transport = transport
    }

    func assess(
        invocation: CodexAppServerInvocation,
        expectedSkillNames: [String],
        forwarderCommand: String,
        legacyGlobalHooksPresent: Bool
    ) throws -> CodexSessionIntegrationAssessment {
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
                CodexAppServerRPCRequest(
                    method: "hooks/list",
                    params: ["cwds": .array([.string(invocation.workingDirectoryURL.path)])]
                ),
            ]
        )
        guard responses.count == 2 else {
            throw CodexAppServerClientError.malformedResponse("assessment")
        }
        let skillsResult = try checkedResult(responses[0], method: "skills/list")
        let hooksResult = try checkedResult(responses[1], method: "hooks/list")

        let expected = Set(expectedSkillNames)
        let skillEntries = skillsResult.objectValue?["data"]?.arrayValue ?? []
        let skillObjects = skillEntries.flatMap { entry in
            entry.objectValue?["skills"]?.arrayValue ?? []
        }.compactMap(\.objectValue)
        let pluginPrefix = "\(CodexSessionIntegrationContract.pluginName):"
        let installedSkills = skillObjects.compactMap { $0["name"]?.stringValue }
            .filter { $0.hasPrefix(pluginPrefix) }
        let enabledSkills = skillObjects.compactMap { skill -> String? in
            guard skill["enabled"]?.boolValue == true,
                  let name = skill["name"]?.stringValue,
                  expected.contains(name) else {
                return nil
            }
            return name
        }
        let skillErrors = skillEntries.flatMap { entry in
            entry.objectValue?["errors"]?.arrayValue ?? []
        }.compactMap { $0.objectValue?["message"]?.stringValue }

        let hookEntries = hooksResult.objectValue?["data"]?.arrayValue ?? []
        let hookObjects = hookEntries.flatMap { entry in
            entry.objectValue?["hooks"]?.arrayValue ?? []
        }.compactMap(\.objectValue)
        let toasttyHookObjects = hookObjects.filter { hook in
            hook["source"]?.stringValue == "sessionFlags"
                && hook["command"]?.stringValue == forwarderCommand
        }
        let sessionHooks = toasttyHookObjects.compactMap { hook -> CodexSessionHookAssessment? in
            guard hook["source"]?.stringValue == "sessionFlags",
                  hook["command"]?.stringValue == forwarderCommand,
                  let eventValue = hook["eventName"]?.stringValue,
                  let event = CodexSessionHookEvent(listValue: eventValue) else {
                return nil
            }
            let expectedDefinition = CodexSessionIntegrationContract.hookDefinitions.first {
                $0.event == event
            }
            let definitionMatchesExpected = expectedDefinition != nil
                && hook["matcher"]?.stringValue == expectedDefinition?.matcher
                && hook["timeoutSec"]?.intValue == CodexSessionIntegrationContract.hookTimeoutSeconds
                && hook["statusMessage"]?.stringValue == CodexSessionIntegrationContract.hookStatusMessage
            return CodexSessionHookAssessment(
                event: event,
                trust: CodexHookTrustState(listValue: hook["trustStatus"]?.stringValue ?? "unknown"),
                definitionHash: hook["currentHash"]?.stringValue,
                definitionMatchesExpected: definitionMatchesExpected
            )
        }
        let warnings = hookEntries.flatMap { entry in
            entry.objectValue?["warnings"]?.arrayValue ?? []
        }.compactMap(\.stringValue)
        let hookErrors = hookEntries.flatMap { entry in
            entry.objectValue?["errors"]?.arrayValue ?? []
        }.compactMap { $0.objectValue?["message"]?.stringValue }
        var identityErrors: [String] = []
        for definition in CodexSessionIntegrationContract.hookDefinitions {
            let matches = toasttyHookObjects.filter { hook in
                hook["eventName"]?.stringValue == definition.event.appServerListValue
            }
            if matches.count != 1 {
                identityErrors.append(
                    "Expected exactly one \(definition.event.rawValue) Toastty session hook; found \(matches.count)."
                )
                continue
            }
            guard let hook = matches.first else { continue }
            if hook["matcher"]?.stringValue != definition.matcher {
                identityErrors.append("Toastty \(definition.event.rawValue) hook matcher differs from the expected definition.")
            }
            if hook["timeoutSec"]?.intValue != CodexSessionIntegrationContract.hookTimeoutSeconds {
                identityErrors.append("Toastty \(definition.event.rawValue) hook timeout differs from the expected definition.")
            }
            if hook["statusMessage"]?.stringValue != CodexSessionIntegrationContract.hookStatusMessage {
                identityErrors.append("Toastty \(definition.event.rawValue) hook status message differs from the expected definition.")
            }
        }

        return CodexSessionIntegrationAssessment(
            support: .supported,
            expectedSkillNames: expectedSkillNames.sorted(),
            installedSkillNames: Array(Set(installedSkills)).sorted(),
            enabledSkillNames: Array(Set(enabledSkills)).sorted(),
            sessionHooks: sessionHooks,
            legacyGlobalHooksPresent: legacyGlobalHooksPresent,
            warnings: warnings,
            errors: skillErrors + hookErrors + identityErrors
        )
    }

    func writeSkillConfig(
        invocation: CodexAppServerInvocation,
        name: String,
        enabled: Bool
    ) throws -> Bool {
        let response = try one(
            invocation: invocation,
            method: "skills/config/write",
            params: ["name": .string(name), "enabled": .bool(enabled)]
        )
        guard let effectiveEnabled = response.objectValue?["effectiveEnabled"]?.boolValue else {
            throw CodexAppServerClientError.malformedResponse("skills/config/write")
        }
        return effectiveEnabled
    }

    func addMarketplace(
        invocation: CodexAppServerInvocation,
        source: String
    ) throws -> String {
        let response = try one(
            invocation: invocation,
            method: "marketplace/add",
            params: ["source": .string(source)]
        )
        guard let name = response.objectValue?["marketplaceName"]?.stringValue else {
            throw CodexAppServerClientError.malformedResponse("marketplace/add")
        }
        return name
    }

    func installPlugin(
        invocation: CodexAppServerInvocation,
        pluginName: String,
        marketplacePath: String
    ) throws {
        _ = try one(
            invocation: invocation,
            method: "plugin/install",
            params: [
                "pluginName": .string(pluginName),
                "marketplacePath": .string(marketplacePath),
            ]
        )
    }

    func upgradeMarketplace(
        invocation: CodexAppServerInvocation,
        marketplaceName: String
    ) throws {
        _ = try one(
            invocation: invocation,
            method: "marketplace/upgrade",
            params: ["marketplaceName": .string(marketplaceName)]
        )
    }

    func uninstallPlugin(
        invocation: CodexAppServerInvocation,
        pluginID: String
    ) throws {
        _ = try one(
            invocation: invocation,
            method: "plugin/uninstall",
            params: ["pluginId": .string(pluginID)]
        )
    }

    func removeMarketplace(
        invocation: CodexAppServerInvocation,
        marketplaceName: String
    ) throws {
        _ = try one(
            invocation: invocation,
            method: "marketplace/remove",
            params: ["marketplaceName": .string(marketplaceName)]
        )
    }

    func installedPluginID(
        invocation: CodexAppServerInvocation,
        pluginName: String,
        marketplaceName: String
    ) throws -> String? {
        let response = try one(
            invocation: invocation,
            method: "plugin/installed",
            params: [:]
        )
        let marketplaces = response.objectValue?["marketplaces"]?.arrayValue ?? []
        for marketplace in marketplaces.compactMap(\.objectValue)
            where marketplace["name"]?.stringValue == marketplaceName {
            let plugins = marketplace["plugins"]?.arrayValue ?? []
            for plugin in plugins.compactMap(\.objectValue)
                where plugin["name"]?.stringValue == pluginName
                    && plugin["installed"]?.boolValue == true {
                return plugin["id"]?.stringValue
            }
        }
        return nil
    }

    func listSkills(
        invocation: CodexAppServerInvocation
    ) throws -> [(name: String, enabled: Bool)] {
        let response = try one(
            invocation: invocation,
            method: "skills/list",
            params: [
                "cwds": .array([.string(invocation.workingDirectoryURL.path)]),
                "forceReload": .bool(true),
            ]
        )
        return (response.objectValue?["data"]?.arrayValue ?? []).flatMap { entry in
            entry.objectValue?["skills"]?.arrayValue ?? []
        }.compactMap { skill in
            guard let object = skill.objectValue,
                  let name = object["name"]?.stringValue,
                  let enabled = object["enabled"]?.boolValue else {
                return nil
            }
            return (name, enabled)
        }
    }

    private func one(
        invocation: CodexAppServerInvocation,
        method: String,
        params: [String: CodexJSONValue]
    ) throws -> CodexJSONValue {
        let responses = try transport.perform(
            invocation: invocation,
            requests: [CodexAppServerRPCRequest(method: method, params: params)]
        )
        guard let response = responses.first else {
            throw CodexAppServerClientError.malformedResponse(method)
        }
        return try checkedResult(response, method: method)
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

private extension CodexSessionHookEvent {
    var appServerListValue: String {
        switch self {
        case .sessionStart: return "sessionStart"
        case .userPromptSubmit: return "userPromptSubmit"
        case .permissionRequest: return "permissionRequest"
        case .preToolUse: return "preToolUse"
        case .subagentStart: return "subagentStart"
        case .subagentStop: return "subagentStop"
        case .stop: return "stop"
        }
    }
}
