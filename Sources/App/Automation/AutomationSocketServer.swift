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

    init(config: AutomationConfig, store: AppStore, terminalRuntimeRegistry: TerminalRuntimeRegistry) throws {
        self.config = config
        self.commandExecutor = AutomationCommandExecutor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            config: config
        )
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
            let envelope = try parseIncomingEnvelope(from: line)
            Task {
                let response = await self.commandExecutor.execute(envelope: envelope)
                completion(self.makeResponseData(for: response))
            }
        } catch let socketError as AutomationSocketError {
            completion(makeResponseData(for: socketError.response))
        } catch {
            completion(makeResponseData(for: AutomationSocketError.internalError(error.localizedDescription).response))
        }
    }

    private func parseIncomingEnvelope(from line: Data) throws -> AutomationIncomingEnvelope {
        do {
            let header = try JSONDecoder().decode(AutomationEnvelopeHeader.self, from: line)
            guard header.protocolVersion.hasPrefix("1.") else {
                throw AutomationSocketError.incompatibleProtocol
            }

            switch header.kind {
            case "request":
                let request = try JSONDecoder().decode(AutomationRequestEnvelope.self, from: line)
                guard request.requestID.isEmpty == false else {
                    throw AutomationSocketError.invalidEnvelope("missing requestID")
                }
                guard request.command.isEmpty == false else {
                    throw AutomationSocketError.invalidEnvelope("missing command")
                }
                return .request(request)

            case "event":
                let event = try JSONDecoder().decode(AutomationEventEnvelope.self, from: line)
                guard event.eventType.isEmpty == false else {
                    throw AutomationSocketError.invalidEnvelope("missing eventType")
                }
                return .event(event)

            default:
                throw AutomationSocketError.invalidEnvelope("kind must be request or event")
            }
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
    private let maxBufferedBytes = 256 * 1024

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
                if buffer.count > maxBufferedBytes {
                    close()
                    return
                }
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
    private let terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let config: AutomationConfig
    private let startedAt = Date()

    private var stateVersion = 0
    private var currentFixtureName: String
    private var sessionRegistry = SessionRegistry()
    private var notificationStore = NotificationStore()
    private var sessionUpdateCoalescer = SessionUpdateCoalescer()
    private var progressBySessionID: [String: String] = [:]
    private var errorsBySessionID: [String: String] = [:]

    init(store: AppStore, terminalRuntimeRegistry: TerminalRuntimeRegistry, config: AutomationConfig) {
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.config = config
        self.currentFixtureName = config.fixtureName ?? "default"
    }

    @MainActor
    func execute(envelope: AutomationIncomingEnvelope) -> AutomationResponseEnvelope {
        let responseRequestID = envelope.requestID ?? UUID().uuidString

        do {
            let result: [String: AutomationJSONValue]?

            switch envelope {
            case .request(let request):
                result = try executeCommand(named: request.command, payload: request.payload)
            case .event(let event):
                result = try executeEvent(event)
            }

            return AutomationResponseEnvelope(
                requestID: responseRequestID,
                ok: true,
                result: result,
                error: nil
            )
        } catch let socketError as AutomationSocketError {
            return AutomationResponseEnvelope(
                requestID: responseRequestID,
                ok: false,
                result: nil,
                error: socketError.errorBody
            )
        } catch {
            return AutomationResponseEnvelope(
                requestID: responseRequestID,
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
            sessionRegistry = SessionRegistry()
            notificationStore = NotificationStore()
            sessionUpdateCoalescer = SessionUpdateCoalescer()
            progressBySessionID.removeAll(keepingCapacity: false)
            errorsBySessionID.removeAll(keepingCapacity: false)
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

        case "automation.terminal_send_text":
            guard let text = payload.string("text") else {
                throw AutomationSocketError.invalidPayload("text is required")
            }
            if payload["waitForSurfaceMs"] != nil {
                throw AutomationSocketError.invalidPayload("waitForSurfaceMs is deprecated; use allowUnavailable=true with client-side retry")
            }
            let submit = payload.bool("submit") ?? false
            let allowUnavailable = payload.bool("allowUnavailable") ?? false
            let resolved = try resolveTerminalTarget(payload: payload)
            if terminalRuntimeRegistry.automationSendText(text, submit: submit, panelID: resolved.panelID) {
                return [
                    "workspaceID": .string(resolved.workspaceID.uuidString),
                    "panelID": .string(resolved.panelID.uuidString),
                    "submitted": .bool(submit),
                    "available": .bool(true),
                ]
            }

            if allowUnavailable {
                return [
                    "workspaceID": .string(resolved.workspaceID.uuidString),
                    "panelID": .string(resolved.panelID.uuidString),
                    "submitted": .bool(submit),
                    "available": .bool(false),
                ]
            }

            throw AutomationSocketError.invalidPayload("terminal surface unavailable for panelID \(resolved.panelID.uuidString)")

        case "automation.terminal_drop_image_files":
            guard payload["files"] != nil else {
                throw AutomationSocketError.invalidPayload("files is required")
            }
            let rawFiles = payload.stringArray("files")
            guard rawFiles.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("files must include at least one path")
            }

            let normalizedFiles: [String]
            do {
                normalizedFiles = try SocketEventNormalizer.normalizeFiles(rawFiles, cwd: payload.string("cwd"))
            } catch let normalizationError as SocketEventNormalizationError {
                switch normalizationError {
                case .missingCWDForRelativePath(let path):
                    throw AutomationSocketError.invalidPayload(
                        "cwd is required when files include relative path: \(path)"
                    )
                }
            }

            let allowUnavailable = payload.bool("allowUnavailable") ?? false
            let resolved = try resolveTerminalTarget(payload: payload)
            switch terminalRuntimeRegistry.automationDropImageFiles(
                normalizedFiles,
                panelID: resolved.panelID
            ) {
            case .sent(let imageCount):
                return [
                    "workspaceID": .string(resolved.workspaceID.uuidString),
                    "panelID": .string(resolved.panelID.uuidString),
                    "requestedFileCount": .int(normalizedFiles.count),
                    "acceptedImageCount": .int(imageCount),
                    "available": .bool(true),
                ]

            case .noImageFiles:
                throw AutomationSocketError.invalidPayload("files payload did not contain any image paths")

            case .unavailableSurface:
                if allowUnavailable {
                    return [
                        "workspaceID": .string(resolved.workspaceID.uuidString),
                        "panelID": .string(resolved.panelID.uuidString),
                        "requestedFileCount": .int(normalizedFiles.count),
                        "acceptedImageCount": .int(0),
                        "available": .bool(false),
                    ]
                }
                throw AutomationSocketError.invalidPayload("terminal surface unavailable for panelID \(resolved.panelID.uuidString)")
            }

        case "automation.terminal_visible_text":
            let resolved = try resolveTerminalTarget(payload: payload)
            guard let text = terminalRuntimeRegistry.automationReadVisibleText(panelID: resolved.panelID) else {
                throw AutomationSocketError.invalidPayload("terminal visible text unavailable for panelID \(resolved.panelID.uuidString)")
            }

            var result: [String: AutomationJSONValue] = [
                "workspaceID": .string(resolved.workspaceID.uuidString),
                "panelID": .string(resolved.panelID.uuidString),
                "text": .string(text),
            ]

            if let needle = payload.string("contains"), needle.isEmpty == false {
                result["contains"] = .bool(text.contains(needle))
            }

            return result

        case "automation.terminal_state":
            let resolved = try resolveTerminalTarget(payload: payload)
            return try terminalStateSnapshot(
                workspaceID: resolved.workspaceID,
                panelID: resolved.panelID
            )

        case "automation.dump_state":
            flushCoalescedUpdates(at: Date())
            let includeRuntime = payload.bool("includeRuntime") ?? false
            let stateData = try encodedStateData(includeRuntime: includeRuntime)
            let stateHash = SHA256.hash(data: stateData).map { String(format: "%02x", $0) }.joined()
            let stateDirectory = try ensureStateArtifactDirectory()
            let outputURL = stateDirectory.appendingPathComponent("state-\(stateVersion).json")
            try stateData.write(to: outputURL, options: [.atomic])
            return [
                "path": .string(outputURL.path),
                "hash": .string(stateHash),
            ]

        case "automation.workspace_snapshot":
            let workspaceID = try resolveWorkspaceID(args: payload)
            return try workspaceSnapshot(workspaceID: workspaceID)

        case "automation.workspace_render_snapshot":
            let workspaceID = try resolveWorkspaceID(args: payload)
            return try workspaceRenderSnapshot(workspaceID: workspaceID)

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
    private func executeEvent(_ event: AutomationEventEnvelope) throws -> [String: AutomationJSONValue]? {
        let now = event.parsedTimestamp ?? Date()
        flushCoalescedUpdates(at: now)

        switch event.eventType {
        case "session.start":
            guard let sessionID = event.sessionID, sessionID.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("sessionID is required")
            }
            let panelID = try event.requiredPanelID()
            guard let agentRaw = event.payload.string("agent"),
                  let agent = AgentKind(rawValue: agentRaw) else {
                throw AutomationSocketError.invalidPayload("agent must be one of: claude, codex")
            }
            guard let location = locatePanel(panelID) else {
                throw AutomationSocketError.invalidPayload("panelID does not exist")
            }

            sessionRegistry.startSession(
                sessionID: sessionID,
                agent: agent,
                panelID: panelID,
                windowID: location.windowID,
                workspaceID: location.workspaceID,
                cwd: event.payload.string("cwd"),
                repoRoot: event.payload.string("repoRoot"),
                at: now
            )
            stateVersion += 1
            return [
                "eventType": .string(event.eventType),
                "stateVersion": .int(stateVersion),
            ]

        case "session.update_files":
            guard let sessionID = event.sessionID, sessionID.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("sessionID is required")
            }
            let panelID = try event.requiredPanelID()
            guard locatePanel(panelID) != nil else {
                throw AutomationSocketError.invalidPayload("panelID does not exist")
            }

            let files = event.payload.stringArray("files")
            guard files.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("files must be a non-empty string array")
            }

            let normalized = try normalizeFiles(files, cwd: event.payload.string("cwd"))
            sessionUpdateCoalescer.ingest(
                SessionFileUpdate(
                    sessionID: sessionID,
                    files: normalized,
                    cwd: event.payload.string("cwd"),
                    repoRoot: event.payload.string("repoRoot")
                ),
                at: now
            )
            stateVersion += 1
            return [
                "eventType": .string(event.eventType),
                "queuedFiles": .int(normalized.count),
                "stateVersion": .int(stateVersion),
            ]

        case "session.needs_input":
            guard event.sessionID?.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("sessionID is required")
            }
            let panelID = try event.requiredPanelID()
            guard let title = event.payload.string("title"), title.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("title is required")
            }
            guard let body = event.payload.string("body"), body.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("body is required")
            }
            guard let location = locatePanel(panelID) else {
                throw AutomationSocketError.invalidPayload("panelID does not exist")
            }

            let decision = notificationStore.record(
                workspaceID: location.workspaceID,
                panelID: panelID,
                title: title,
                body: body,
                appIsFocused: NSApplication.shared.isActive,
                sourcePanelIsFocused: isPanelFocused(panelID),
                at: now
            )
            handleNotificationDelivery(
                decision: decision,
                title: title,
                body: body,
                workspaceID: location.workspaceID,
                panelID: panelID
            )
            stateVersion += 1
            return [
                "eventType": .string(event.eventType),
                "notificationStored": .bool(decision.stored),
                "sendSystemNotification": .bool(decision.shouldSendSystemNotification),
                "stateVersion": .int(stateVersion),
            ]

        case "session.progress":
            guard let sessionID = event.sessionID, sessionID.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("sessionID is required")
            }
            let _ = try event.requiredPanelID()
            guard let message = event.payload.string("message"), message.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("message is required")
            }
            progressBySessionID[sessionID] = message
            stateVersion += 1
            return [
                "eventType": .string(event.eventType),
                "stateVersion": .int(stateVersion),
            ]

        case "session.error":
            guard let sessionID = event.sessionID, sessionID.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("sessionID is required")
            }
            let _ = try event.requiredPanelID()
            guard let message = event.payload.string("message"), message.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("message is required")
            }
            errorsBySessionID[sessionID] = message
            stateVersion += 1
            return [
                "eventType": .string(event.eventType),
                "stateVersion": .int(stateVersion),
            ]

        case "session.stop":
            guard let sessionID = event.sessionID, sessionID.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("sessionID is required")
            }
            let _ = try event.requiredPanelID()
            flushAllCoalescedUpdates()
            sessionRegistry.stopSession(sessionID: sessionID, at: now)
            progressBySessionID.removeValue(forKey: sessionID)
            errorsBySessionID.removeValue(forKey: sessionID)
            stateVersion += 1
            return [
                "eventType": .string(event.eventType),
                "stateVersion": .int(stateVersion),
            ]

        case "notification.emit":
            guard let title = event.payload.string("title"), title.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("title is required")
            }
            guard let body = event.payload.string("body"), body.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("body is required")
            }

            let payloadWorkspaceID = event.payload.uuid("workspaceID")
            let payloadPanelID = event.payload.uuid("panelID")

            let resolvedWorkspaceID: UUID
            if let payloadWorkspaceID {
                guard store.state.workspacesByID[payloadWorkspaceID] != nil else {
                    throw AutomationSocketError.invalidPayload("workspaceID does not exist")
                }
                resolvedWorkspaceID = payloadWorkspaceID
            } else if let payloadPanelID {
                guard let location = locatePanel(payloadPanelID) else {
                    throw AutomationSocketError.invalidPayload("panelID does not exist")
                }
                resolvedWorkspaceID = location.workspaceID
            } else if let selectedWorkspaceID = store.selectedWorkspace?.id {
                resolvedWorkspaceID = selectedWorkspaceID
            } else {
                throw AutomationSocketError.invalidPayload("unable to resolve workspace")
            }

            let decision = notificationStore.record(
                workspaceID: resolvedWorkspaceID,
                panelID: payloadPanelID,
                title: title,
                body: body,
                appIsFocused: NSApplication.shared.isActive,
                sourcePanelIsFocused: payloadPanelID.map(isPanelFocused) ?? false,
                at: now
            )
            handleNotificationDelivery(
                decision: decision,
                title: title,
                body: body,
                workspaceID: resolvedWorkspaceID,
                panelID: payloadPanelID
            )
            stateVersion += 1
            return [
                "eventType": .string(event.eventType),
                "notificationStored": .bool(decision.stored),
                "sendSystemNotification": .bool(decision.shouldSendSystemNotification),
                "stateVersion": .int(stateVersion),
            ]

        default:
            throw AutomationSocketError.unknownEventType
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

        case "workspace.split.right":
            didMutate = store.send(.splitFocusedPaneInDirection(workspaceID: workspaceID, direction: .right))

        case "workspace.split.down":
            didMutate = store.send(.splitFocusedPaneInDirection(workspaceID: workspaceID, direction: .down))

        case "workspace.split.left":
            didMutate = store.send(.splitFocusedPaneInDirection(workspaceID: workspaceID, direction: .left))

        case "workspace.split.up":
            didMutate = store.send(.splitFocusedPaneInDirection(workspaceID: workspaceID, direction: .up))

        case "workspace.close-focused-panel":
            guard let focusedPanelID = store.state.workspacesByID[workspaceID]?.focusedPanelID else {
                throw AutomationSocketError.invalidPayload("focused panel missing")
            }
            didMutate = store.send(.closePanel(panelID: focusedPanelID))

        case "workspace.focus-pane.previous":
            didMutate = store.send(.focusPane(workspaceID: workspaceID, direction: .previous))

        case "workspace.focus-pane.next":
            didMutate = store.send(.focusPane(workspaceID: workspaceID, direction: .next))

        case "workspace.focus-pane.left":
            didMutate = store.send(.focusPane(workspaceID: workspaceID, direction: .left))

        case "workspace.focus-pane.right":
            didMutate = store.send(.focusPane(workspaceID: workspaceID, direction: .right))

        case "workspace.focus-pane.up":
            didMutate = store.send(.focusPane(workspaceID: workspaceID, direction: .up))

        case "workspace.focus-pane.down":
            didMutate = store.send(.focusPane(workspaceID: workspaceID, direction: .down))

        case "workspace.focus-panel":
            guard let panelID = args.uuid("panelID") else {
                throw AutomationSocketError.invalidPayload("panelID must be a UUID")
            }
            didMutate = store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))

        case "workspace.resize-split.left":
            didMutate = store.send(
                .resizeFocusedPaneSplit(
                    workspaceID: workspaceID,
                    direction: .left,
                    amount: max(args.int("amount") ?? 1, 1)
                )
            )

        case "workspace.resize-split.right":
            didMutate = store.send(
                .resizeFocusedPaneSplit(
                    workspaceID: workspaceID,
                    direction: .right,
                    amount: max(args.int("amount") ?? 1, 1)
                )
            )

        case "workspace.resize-split.up":
            didMutate = store.send(
                .resizeFocusedPaneSplit(
                    workspaceID: workspaceID,
                    direction: .up,
                    amount: max(args.int("amount") ?? 1, 1)
                )
            )

        case "workspace.resize-split.down":
            didMutate = store.send(
                .resizeFocusedPaneSplit(
                    workspaceID: workspaceID,
                    direction: .down,
                    amount: max(args.int("amount") ?? 1, 1)
                )
            )

        case "workspace.equalize-splits":
            didMutate = store.send(.equalizePaneSplits(workspaceID: workspaceID))

        case "topbar.toggle.diff":
            didMutate = store.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff))

        case "topbar.toggle.markdown":
            didMutate = store.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown))

        case "topbar.toggle.scratchpad":
            didMutate = store.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .scratchpad))

        case "topbar.toggle.focused-panel":
            didMutate = store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))

        case "app.font.increase":
            didMutate = store.send(.increaseGlobalTerminalFont)

        case "app.font.decrease":
            didMutate = store.send(.decreaseGlobalTerminalFont)

        case "app.font.reset":
            didMutate = store.send(.resetGlobalTerminalFont)

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
    private func resolveTerminalTarget(payload: [String: AutomationJSONValue]) throws -> (workspaceID: UUID, panelID: UUID) {
        if let rawPanelID = payload.string("panelID") {
            guard let panelID = UUID(uuidString: rawPanelID) else {
                throw AutomationSocketError.invalidPayload("panelID must be a UUID")
            }
            guard let location = locatePanel(panelID) else {
                throw AutomationSocketError.invalidPayload("panelID does not exist")
            }
            guard let workspace = store.state.workspacesByID[location.workspaceID],
                  let panelState = workspace.panels[panelID],
                  case .terminal = panelState else {
                throw AutomationSocketError.invalidPayload("panelID is not a terminal panel")
            }
            return (location.workspaceID, panelID)
        }

        let workspaceID = try resolveWorkspaceID(args: payload)
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }

        if let focusedPanelID = workspace.focusedPanelID,
           let panelState = workspace.panels[focusedPanelID],
           case .terminal = panelState {
            return (workspaceID, focusedPanelID)
        }

        for leaf in workspace.paneTree.allLeafInfos {
            for panelID in leaf.tabPanelIDs {
                if let panelState = workspace.panels[panelID], case .terminal = panelState {
                    return (workspaceID, panelID)
                }
            }
        }

        throw AutomationSocketError.invalidPayload("workspace has no terminal panel to target")
    }

    @MainActor
    private func encodedStateData(includeRuntime: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if includeRuntime {
            flushAllCoalescedUpdates()
            let snapshot = AutomationRuntimeStateDump(
                appState: store.state,
                sessionRegistry: sessionRegistry,
                notifications: notificationStore.notifications,
                progressBySessionID: progressBySessionID,
                errorsBySessionID: errorsBySessionID
            )
            return try encoder.encode(snapshot)
        }
        return try encoder.encode(store.state)
    }

    @MainActor
    private func terminalStateSnapshot(
        workspaceID: UUID,
        panelID: UUID
    ) throws -> [String: AutomationJSONValue] {
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }
        guard let panelState = workspace.panels[panelID],
              case .terminal(let terminalState) = panelState else {
            throw AutomationSocketError.invalidPayload("panelID is not a terminal panel")
        }
        return [
            "workspaceID": .string(workspaceID.uuidString),
            "panelID": .string(panelID.uuidString),
            "title": .string(terminalState.title),
            "cwd": .string(terminalState.cwd),
            "shell": .string(terminalState.shell),
        ]
    }

    @MainActor
    private func workspaceSnapshot(workspaceID: UUID) throws -> [String: AutomationJSONValue] {
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }

        let leafInfos = workspace.paneTree.allLeafInfos
        let leafPaneIDs = leafInfos.map { AutomationJSONValue.string($0.paneID.uuidString) }
        let leafPanelIDs = leafInfos.flatMap { info in
            info.tabPanelIDs.map { AutomationJSONValue.string($0.uuidString) }
        }
        let rootSplitRatio: AutomationJSONValue
        switch workspace.paneTree {
        case .split(_, _, let ratio, _, _):
            rootSplitRatio = .double(ratio)
        case .leaf:
            rootSplitRatio = .null
        }

        return [
            "workspaceID": .string(workspaceID.uuidString),
            "paneCount": .int(leafInfos.count),
            "panelCount": .int(workspace.panels.count),
            "focusedPanelID": workspace.focusedPanelID.map { .string($0.uuidString) } ?? .null,
            "rootSplitRatio": rootSplitRatio,
            "leafPaneIDs": .array(leafPaneIDs),
            "leafPanelIDs": .array(leafPanelIDs),
        ]
    }

    @MainActor
    private func workspaceRenderSnapshot(workspaceID: UUID) throws -> [String: AutomationJSONValue] {
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }

        let terminalPanelIDs: [UUID] = workspace.paneTree.allLeafInfos.flatMap { paneInfo in
            paneInfo.tabPanelIDs.filter { panelID in
                guard let panelState = workspace.panels[panelID] else {
                    return false
                }
                if case .terminal = panelState {
                    return true
                }
                return false
            }
        }

        var allRenderable = true
        let panelRenderStates: [AutomationJSONValue] = terminalPanelIDs.map { panelID in
            let snapshot = terminalRuntimeRegistry.automationRenderSnapshot(panelID: panelID)
            allRenderable = allRenderable && snapshot.isRenderable
            return .object([
                "panelID": .string(snapshot.panelID.uuidString),
                "controllerExists": .bool(snapshot.controllerExists),
                "hostHasSuperview": .bool(snapshot.hostHasSuperview),
                "hostAttachedToWindow": .bool(snapshot.hostAttachedToWindow),
                "sourceContainerExists": .bool(snapshot.sourceContainerExists),
                "sourceContainerAttachedToWindow": .bool(snapshot.sourceContainerAttachedToWindow),
                "hostSuperviewMatchesSourceContainer": .bool(snapshot.hostSuperviewMatchesSourceContainer),
                "bindingEpoch": .string(String(snapshot.bindingEpoch)),
                "ghosttySurfaceAvailable": .bool(snapshot.ghosttySurfaceAvailable),
                "isRenderable": .bool(snapshot.isRenderable),
            ])
        }

        return [
            "workspaceID": .string(workspaceID.uuidString),
            "terminalPanelCount": .int(terminalPanelIDs.count),
            "allRenderable": .bool(allRenderable),
            "panels": .array(panelRenderStates),
        ]
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
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) else {
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

    @MainActor
    private func locatePanel(_ panelID: UUID) -> (windowID: UUID, workspaceID: UUID)? {
        for window in store.state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = store.state.workspacesByID[workspaceID] else { continue }
                if workspace.panels[panelID] != nil {
                    return (window.id, workspaceID)
                }
            }
        }
        return nil
    }

    @MainActor
    private func isPanelFocused(_ panelID: UUID) -> Bool {
        guard let selectedWorkspaceID = store.selectedWorkspace?.id,
              let selectedWorkspace = store.state.workspacesByID[selectedWorkspaceID] else {
            return false
        }
        guard selectedWorkspace.focusedPanelID == panelID else {
            return false
        }
        return selectedWorkspace.paneTree.leafContaining(panelID: panelID) != nil
    }

    @MainActor
    private func handleNotificationDelivery(
        decision: NotificationDecision,
        title: String,
        body: String,
        workspaceID: UUID,
        panelID: UUID?
    ) {
        guard decision.stored else {
            return
        }

        _ = store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panelID))

        guard decision.shouldSendSystemNotification else {
            return
        }

        let notificationContext = desktopNotificationContext(workspaceID: workspaceID, panelID: panelID)

        Task {
            await SystemNotificationSender.send(
                title: title,
                body: body,
                workspaceID: workspaceID,
                panelID: panelID,
                context: notificationContext
            )
        }
    }

    @MainActor
    private func desktopNotificationContext(workspaceID: UUID, panelID: UUID?) -> DesktopNotificationContext {
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            return DesktopNotificationContext()
        }
        let panelLabel = panelID.flatMap { workspace.panels[$0]?.notificationLabel }
        return DesktopNotificationContext(workspaceTitle: workspace.title, panelLabel: panelLabel)
    }

    private func normalizeFiles(_ files: [String], cwd: String?) throws -> [String] {
        do {
            return try SocketEventNormalizer.normalizeFiles(files, cwd: cwd)
        } catch let error as SocketEventNormalizationError {
            switch error {
            case .missingCWDForRelativePath:
                throw AutomationSocketError.invalidPayload("cwd is required when files include relative paths")
            }
        } catch {
            throw AutomationSocketError.internalError("file normalization failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func flushCoalescedUpdates(at now: Date) {
        let updates = sessionUpdateCoalescer.flushReady(at: now)
        for update in updates {
            sessionRegistry.updateFiles(
                sessionID: update.sessionID,
                files: update.files,
                cwd: update.cwd,
                repoRoot: update.repoRoot,
                at: now
            )
        }
    }

    @MainActor
    private func flushAllCoalescedUpdates() {
        let now = Date()
        let updates = sessionUpdateCoalescer.flushAll()
        for update in updates {
            sessionRegistry.updateFiles(
                sessionID: update.sessionID,
                files: update.files,
                cwd: update.cwd,
                repoRoot: update.repoRoot,
                at: now
            )
        }
    }
}

private enum AutomationIncomingEnvelope: Sendable {
    case request(AutomationRequestEnvelope)
    case event(AutomationEventEnvelope)

    var requestID: String? {
        switch self {
        case .request(let request):
            return request.requestID
        case .event(let event):
            return event.requestID
        }
    }
}

private struct AutomationEnvelopeHeader: Decodable, Sendable {
    let protocolVersion: String
    let kind: String
}

private struct AutomationEventEnvelope: Decodable, Sendable {
    let protocolVersion: String
    let kind: String
    let requestID: String?
    let eventType: String
    let sessionID: String?
    let panelID: String?
    let timestamp: String?
    let payload: [String: AutomationJSONValue]

    func requiredPanelID() throws -> UUID {
        guard let panelID,
              let uuid = UUID(uuidString: panelID) else {
            throw AutomationSocketError.invalidPayload("panelID must be a UUID")
        }
        return uuid
    }

    var parsedTimestamp: Date? {
        guard let timestamp else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFractional.date(from: timestamp) {
            return parsed
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: timestamp)
    }
}

private struct AutomationRuntimeStateDump: Encodable, Sendable {
    let appState: AppState
    let sessionRegistry: SessionRegistry
    let notifications: [ToasttyNotification]
    let progressBySessionID: [String: String]
    let errorsBySessionID: [String: String]
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

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value)? = self[key] else {
            return nil
        }
        return value
    }

    func int(_ key: String) -> Int? {
        guard case .int(let value)? = self[key] else {
            return nil
        }
        return value
    }

    func uuid(_ key: String) -> UUID? {
        guard let value = string(key) else { return nil }
        return UUID(uuidString: value)
    }

    func stringArray(_ key: String) -> [String] {
        guard case .array(let values)? = self[key] else {
            return []
        }
        return values.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value
        }
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
    case unknownEventType
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
        case .unknownEventType:
            return AutomationResponseError(code: "UNKNOWN_EVENT_TYPE", message: "eventType is not supported")
        case .unknownCommand:
            return AutomationResponseError(code: "UNKNOWN_COMMAND", message: "command is not supported")
        case .invalidPayload(let message):
            return AutomationResponseError(code: "INVALID_PAYLOAD", message: message)
        case .internalError(let message):
            return AutomationResponseError(code: "INTERNAL_ERROR", message: message)
        }
    }
}
