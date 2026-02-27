import AppKit
import CoreState
import CryptoKit
import Darwin
import Foundation

final class AutomationSocketServer: @unchecked Sendable {
    private let config: AutomationConfig
    private let commandExecutor: AutomationCommandExecutor
    private let queue = DispatchQueue(label: "toastty.automation.socket")

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: AutomationSocketClient] = [:]

    init(config: AutomationConfig, store: AppStore) throws {
        self.config = config
        self.commandExecutor = AutomationCommandExecutor(store: store, config: config)
        try startListening()
    }

    deinit {
        stopListening()
    }

    private func startListening() throws {
        let socketURL = URL(fileURLWithPath: config.socketPath, isDirectory: false)
        let directoryURL = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        _ = chmod(directoryURL.path, 0o700)

        // Remove any stale socket left by prior runs.
        _ = unlink(config.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AutomationSocketError.internalError("socket() failed: \(errno)")
        }
        try setNonBlocking(fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(config.socketPath.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            close(fd)
            throw AutomationSocketError.invalidPayload("socket path too long: \(config.socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                if let destinationAddress = buffer.baseAddress, let sourceAddress = source.baseAddress {
                    memcpy(destinationAddress, sourceAddress, pathBytes.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw AutomationSocketError.internalError("bind() failed: \(errno)")
        }

        _ = chmod(config.socketPath, 0o600)

        guard listen(fd, SOMAXCONN) == 0 else {
            close(fd)
            throw AutomationSocketError.internalError("listen() failed: \(errno)")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listenFD >= 0 {
                close(self.listenFD)
                self.listenFD = -1
            }
        }

        listenFD = fd
        acceptSource = source
        source.resume()
    }

    private func stopListening() {
        acceptSource?.cancel()
        acceptSource = nil
        for client in clients.values {
            client.close()
        }
        clients.removeAll()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        _ = unlink(config.socketPath)
    }

    private func acceptConnections() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }

            do {
                try setNonBlocking(clientFD)
            } catch {
                close(clientFD)
                continue
            }

            let client = AutomationSocketClient(
                fileDescriptor: clientFD,
                queue: queue,
                requestHandler: { [weak self] requestLine, completion in
                    self?.handleRequestLine(requestLine, completion: completion)
                },
                closeHandler: { [weak self] fd in
                    self?.clients.removeValue(forKey: fd)
                }
            )
            clients[clientFD] = client
            client.start()
        }
    }

    private func handleRequestLine(_ line: Data, completion: @escaping @Sendable (Data) -> Void) {
        do {
            let envelope = try parseRequestEnvelope(from: line)
            Task {
                let response = await self.commandExecutor.execute(request: envelope)
                completion(self.makeResponseData(for: response))
            }
        } catch let socketError as AutomationSocketError {
            completion(makeResponseData(for: socketError.response))
        } catch {
            completion(makeResponseData(for: AutomationSocketError.internalError(error.localizedDescription).response))
        }
    }

    private func parseRequestEnvelope(from line: Data) throws -> AutomationRequestEnvelope {
        do {
            let envelope = try JSONDecoder().decode(AutomationRequestEnvelope.self, from: line)
            guard envelope.protocolVersion.hasPrefix("1.") else {
                throw AutomationSocketError.incompatibleProtocol
            }
            guard envelope.kind == "request" else {
                throw AutomationSocketError.invalidEnvelope("kind must be request")
            }
            guard envelope.requestID.isEmpty == false else {
                throw AutomationSocketError.invalidEnvelope("missing requestID")
            }
            guard envelope.command.isEmpty == false else {
                throw AutomationSocketError.invalidEnvelope("missing command")
            }
            return envelope
        } catch {
            if error is DecodingError {
                throw AutomationSocketError.invalidJSON
            }
            throw error
        }
    }

    private func makeResponseData(for response: AutomationResponseEnvelope) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(response)) ?? Data()
        return data + Data([0x0A])
    }

    private func setNonBlocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            throw AutomationSocketError.internalError("fcntl(F_GETFL) failed: \(errno)")
        }
        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw AutomationSocketError.internalError("fcntl(F_SETFL) failed: \(errno)")
        }
    }
}

private final class AutomationSocketClient: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let queue: DispatchQueue
    private let requestHandler: (Data, @escaping @Sendable (Data) -> Void) -> Void
    private let closeHandler: (Int32) -> Void
    private let source: DispatchSourceRead

    private var buffer = Data()
    private var didHandleRequest = false
    private var isClosed = false

    init(
        fileDescriptor: Int32,
        queue: DispatchQueue,
        requestHandler: @escaping (Data, @escaping @Sendable (Data) -> Void) -> Void,
        closeHandler: @escaping (Int32) -> Void
    ) {
        self.fileDescriptor = fileDescriptor
        self.queue = queue
        self.requestHandler = requestHandler
        self.closeHandler = closeHandler
        self.source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
    }

    func start() {
        source.setEventHandler { [weak self] in
            self?.readAvailableBytes()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                _ = Darwin.close(self.fileDescriptor)
            }
            self.closeHandler(self.fileDescriptor)
        }
        source.resume()
    }

    func close() {
        guard isClosed == false else { return }
        isClosed = true
        source.cancel()
    }

    private func readAvailableBytes() {
        guard didHandleRequest == false else { return }

        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = Darwin.read(fileDescriptor, &chunk, chunk.count)
            if bytesRead > 0 {
                buffer.append(chunk, count: bytesRead)
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: newlineIndex)
                    didHandleRequest = true
                    requestHandler(Data(line)) { [weak self] responseData in
                        guard let self else { return }
                        self.queue.async {
                            self.writeResponseAndClose(responseData)
                        }
                    }
                    return
                }
            } else if bytesRead == 0 {
                close()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                close()
                return
            }
        }
    }

    private func writeResponseAndClose(_ responseData: Data) {
        responseData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < responseData.count {
                let result = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: bytesWritten),
                    responseData.count - bytesWritten
                )
                if result > 0 {
                    bytesWritten += result
                    continue
                }
                if result < 0 && errno == EINTR {
                    continue
                }
                break
            }
        }
        close()
    }
}

private final class AutomationCommandExecutor: @unchecked Sendable {
    private let store: AppStore
    private let config: AutomationConfig
    private let startedAt = Date()

    private var stateVersion = 0
    private var currentFixtureName: String

    init(store: AppStore, config: AutomationConfig) {
        self.store = store
        self.config = config
        self.currentFixtureName = config.fixtureName ?? "default"
    }

    func execute(request: AutomationRequestEnvelope) async -> AutomationResponseEnvelope {
        do {
            let result = try await executeCommand(named: request.command, payload: request.payload)
            return AutomationResponseEnvelope(
                requestID: request.requestID,
                ok: true,
                result: result,
                error: nil
            )
        } catch let socketError as AutomationSocketError {
            return AutomationResponseEnvelope(
                requestID: request.requestID,
                ok: false,
                result: nil,
                error: socketError.errorBody
            )
        } catch {
            return AutomationResponseEnvelope(
                requestID: request.requestID,
                ok: false,
                result: nil,
                error: AutomationResponseError(
                    code: "INTERNAL_ERROR",
                    message: error.localizedDescription
                )
            )
        }
    }

    @MainActor
    private func executeCommand(
        named command: String,
        payload: [String: AutomationJSONValue]
    ) throws -> [String: AutomationJSONValue]? {
        switch command {
        case "automation.ping":
            return [
                "status": .string("ok"),
                "automationEnabled": .bool(true),
                "appUptimeMs": .int(Int(Date().timeIntervalSince(startedAt) * 1000)),
                "protocolVersion": .string("1.0"),
            ]

        case "automation.reset":
            store.replaceState(.bootstrap())
            currentFixtureName = "default"
            stateVersion += 1
            return [
                "stateVersion": .int(stateVersion),
            ]

        case "automation.load_fixture":
            guard let fixtureName = payload.string("name"), fixtureName.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("name is required")
            }
            let state = try AutomationFixtureLoader.loadRequired(named: fixtureName)
            store.replaceState(state)
            currentFixtureName = fixtureName
            stateVersion += 1
            return [
                "fixture": .string(fixtureName),
                "stateVersion": .int(stateVersion),
            ]

        case "automation.perform_action":
            guard let actionID = payload.string("action"), actionID.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("action is required")
            }
            let args = payload.object("args") ?? [:]
            try performAction(actionID: actionID, args: args)
            stateVersion += 1
            return [
                "stateVersion": .int(stateVersion),
            ]

        case "automation.dump_state":
            let stateData = try encodedStateData()
            let stateHash = SHA256.hash(data: stateData).map { String(format: "%02x", $0) }.joined()
            let stateDirectory = try ensureStateArtifactDirectory()
            let outputURL = stateDirectory.appendingPathComponent("state-\(stateVersion).json")
            try stateData.write(to: outputURL, options: [.atomic])
            return [
                "path": .string(outputURL.path),
                "hash": .string(stateHash),
            ]

        case "automation.capture_screenshot":
            guard let step = payload.string("step"), step.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("step is required")
            }
            let requestedFixture = payload.string("fixture")
            if let requestedFixture, requestedFixture != currentFixtureName {
                throw AutomationSocketError.invalidPayload("fixture does not match currently loaded fixture")
            }
            let fixture = requestedFixture ?? currentFixtureName
            let screenshotURL = try screenshotURL(fixture: fixture, step: step)
            let screenshotData = try captureScreenshotPNG()
            try screenshotData.write(to: screenshotURL, options: [.atomic])
            return [
                "path": .string(screenshotURL.path),
            ]

        default:
            throw AutomationSocketError.unknownCommand
        }
    }

    @MainActor
    private func performAction(actionID: String, args: [String: AutomationJSONValue]) throws {
        let workspaceID = try resolveWorkspaceID(args: args)

        let didMutate: Bool
        switch actionID {
        case "workspace.split.horizontal":
            didMutate = store.send(.splitFocusedPane(workspaceID: workspaceID, orientation: .horizontal))

        case "workspace.split.vertical":
            didMutate = store.send(.splitFocusedPane(workspaceID: workspaceID, orientation: .vertical))

        case "topbar.toggle.diff":
            didMutate = store.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff))

        case "topbar.toggle.markdown":
            didMutate = store.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown))

        case "topbar.toggle.scratchpad":
            didMutate = store.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .scratchpad))

        case "sidebar.workspaces.new":
            guard let windowID = resolveWindowID(args: args) else {
                throw AutomationSocketError.invalidPayload("windowID not found")
            }
            let title = args.string("title")
            didMutate = store.send(.createWorkspace(windowID: windowID, title: title))

        default:
            throw AutomationSocketError.invalidPayload("unsupported action: \(actionID)")
        }

        guard didMutate else {
            throw AutomationSocketError.invalidPayload("action could not be applied: \(actionID)")
        }
    }

    @MainActor
    private func resolveWorkspaceID(args: [String: AutomationJSONValue]) throws -> UUID {
        if let rawWorkspaceID = args.string("workspaceID") {
            guard let workspaceID = UUID(uuidString: rawWorkspaceID) else {
                throw AutomationSocketError.invalidPayload("workspaceID must be a UUID")
            }
            guard store.state.workspacesByID[workspaceID] != nil else {
                throw AutomationSocketError.invalidPayload("workspaceID does not exist")
            }
            return workspaceID
        }
        guard let workspaceID = store.selectedWorkspace?.id else {
            throw AutomationSocketError.invalidPayload("no selected workspace")
        }
        return workspaceID
    }

    @MainActor
    private func resolveWindowID(args: [String: AutomationJSONValue]) -> UUID? {
        if let rawWindowID = args.string("windowID"), let windowID = UUID(uuidString: rawWindowID) {
            return windowID
        }
        return store.selectedWindow?.id
    }

    @MainActor
    private func encodedStateData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.state)
    }

    private func ensureStateArtifactDirectory() throws -> URL {
        let directory = try ensureRunArtifactDirectory().appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func screenshotURL(fixture: String, step: String) throws -> URL {
        let fixtureComponent = sanitizedPathComponent(fixture)
        let stepComponent = sanitizedPathComponent(step)
        let directory = try ensureRunArtifactDirectory().appendingPathComponent(fixtureComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(stepComponent).png")
    }

    private func ensureRunArtifactDirectory() throws -> URL {
        let rootDirectory = URL(fileURLWithPath: config.artifactsDirectory ?? FileManager.default.temporaryDirectory.path, isDirectory: true)
            .appendingPathComponent("ui", isDirectory: true)
            .appendingPathComponent(sanitizedPathComponent(config.runID), isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        return rootDirectory
    }

    @MainActor
    private func captureScreenshotPNG() throws -> Data {
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) ?? NSApplication.shared.keyWindow else {
            throw AutomationSocketError.internalError("no visible app window")
        }
        window.displayIfNeeded()

        guard let contentView = window.contentView else {
            throw AutomationSocketError.internalError("window has no content view")
        }
        let bounds = contentView.bounds.integral
        guard bounds.width > 0, bounds.height > 0 else {
            throw AutomationSocketError.internalError("window content bounds are empty")
        }

        guard let imageRep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw AutomationSocketError.internalError("failed to create image representation")
        }
        contentView.cacheDisplay(in: bounds, to: imageRep)
        guard let data = imageRep.representation(using: .png, properties: [:]) else {
            throw AutomationSocketError.internalError("failed to encode png")
        }
        return data
    }

    private func sanitizedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let transformed = value.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return transformed.isEmpty ? "value" : transformed
    }
}

private struct AutomationRequestEnvelope: Decodable, Sendable {
    let protocolVersion: String
    let kind: String
    let requestID: String
    let command: String
    let payload: [String: AutomationJSONValue]

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case kind
        case requestID
        case command
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        kind = try container.decode(String.self, forKey: .kind)
        requestID = try container.decode(String.self, forKey: .requestID)
        command = try container.decode(String.self, forKey: .command)
        payload = try container.decodeIfPresent([String: AutomationJSONValue].self, forKey: .payload) ?? [:]
    }
}

private struct AutomationResponseEnvelope: Encodable, Sendable {
    let protocolVersion: String
    let kind: String
    let requestID: String
    let ok: Bool
    let result: [String: AutomationJSONValue]?
    let error: AutomationResponseError?

    init(
        requestID: String,
        ok: Bool,
        result: [String: AutomationJSONValue]?,
        error: AutomationResponseError?
    ) {
        self.protocolVersion = "1.0"
        self.kind = "response"
        self.requestID = requestID
        self.ok = ok
        self.result = result
        self.error = error
    }
}

private struct AutomationResponseError: Encodable, Sendable {
    let code: String
    let message: String
}

private enum AutomationJSONValue: Sendable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AutomationJSONValue])
    case array([AutomationJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: AutomationJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AutomationJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported json value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

private extension Dictionary where Key == String, Value == AutomationJSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else {
            return nil
        }
        return value
    }

    func object(_ key: String) -> [String: AutomationJSONValue]? {
        guard case .object(let value)? = self[key] else {
            return nil
        }
        return value
    }
}

private enum AutomationSocketError: Error {
    case invalidJSON
    case invalidEnvelope(String)
    case incompatibleProtocol
    case unknownCommand
    case invalidPayload(String)
    case internalError(String)

    var response: AutomationResponseEnvelope {
        AutomationResponseEnvelope(
            requestID: "unknown",
            ok: false,
            result: nil,
            error: errorBody
        )
    }

    var errorBody: AutomationResponseError {
        switch self {
        case .invalidJSON:
            return AutomationResponseError(code: "INVALID_JSON", message: "request body must be valid JSON")
        case .invalidEnvelope(let message):
            return AutomationResponseError(code: "INVALID_ENVELOPE", message: message)
        case .incompatibleProtocol:
            return AutomationResponseError(code: "INCOMPATIBLE_PROTOCOL", message: "unsupported protocolVersion")
        case .unknownCommand:
            return AutomationResponseError(code: "UNKNOWN_COMMAND", message: "command is not supported")
        case .invalidPayload(let message):
            return AutomationResponseError(code: "INVALID_PAYLOAD", message: message)
        case .internalError(let message):
            return AutomationResponseError(code: "INTERNAL_ERROR", message: message)
        }
    }
}
