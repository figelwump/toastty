import AppKit
import CoreState
import CryptoKit
import Darwin
import Foundation

struct AutomationSocketServerRecoveryPolicy {
    let retryDelays: [TimeInterval]

    static let `default` = AutomationSocketServerRecoveryPolicy(retryDelays: [0.25, 1.0, 3.0])
}

struct AutomationSocketServerTestHooks {
    enum AcceptResult: Sendable {
        case useSystemAccept
        case fail(Int32)
    }

    var acceptOverride: (@Sendable (Int32) -> AcceptResult)?
    var listenerDidStart: (@Sendable (_ fileDescriptor: Int32, _ recoveryAttempt: Int?) -> Void)?
    var recoveryDidSchedule: (@Sendable (_ attempt: Int, _ errorNumber: Int32, _ delay: TimeInterval) -> Void)?

    static let disabled = AutomationSocketServerTestHooks()
}

enum AutomationSocketStartupError: LocalizedError, Equatable {
    case liveSocketPathInUse(String)
    case socketPathInspectionFailed(String, errorNumber: Int32)

    var errorDescription: String? {
        switch self {
        case .liveSocketPathInUse(let socketPath):
            return "automation socket path is already owned by a live listener: \(socketPath)"
        case .socketPathInspectionFailed(let socketPath, let errorNumber):
            let errorMessage = String(cString: strerror(errorNumber))
            return "failed to inspect existing automation socket path \(socketPath): \(errorMessage)"
        }
    }
}

private enum AutomationSocketBindingAvailability: Equatable {
    case available
    case stale
    case live
    case inspectionFailed(Int32)
}

final class AutomationSocketServer: @unchecked Sendable {
    private static let liveSocketProbeRetryDelayMicros: useconds_t = 10_000
    private static let liveSocketProbeAttemptCount = 3

    private struct PendingListenerRecovery {
        let attempt: Int
        let triggeringErrno: Int32
        let delay: TimeInterval
    }

    private let socketPath: String
    private let processEnvironment: [String: String]
    private let publishesDiscoveryRecord: Bool
    private let commandExecutor: AutomationCommandExecutor
    private let recoveryPolicy: AutomationSocketServerRecoveryPolicy
    private let testHooks: AutomationSocketServerTestHooks
    private let queue = DispatchQueue(label: "toastty.automation.socket")

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: AutomationSocketClient] = [:]
    private var isStopping = false
    private var ownsSocketPath = false
    private var publishedDiscoveryRecord = false
    private var pendingRecovery: PendingListenerRecovery?
    private var recoveryAttemptCount = 0

    init(
        socketPath: String,
        automationConfig: AutomationConfig?,
        publishesDiscoveryRecord: Bool? = nil,
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        sessionRuntimeStore: SessionRuntimeStore,
        focusedPanelCommandController: FocusedPanelCommandController,
        agentLaunchService: AgentLaunchService,
        recoveryPolicy: AutomationSocketServerRecoveryPolicy = .default,
        testHooks: AutomationSocketServerTestHooks = .disabled
    ) throws {
        self.socketPath = socketPath
        self.processEnvironment = ProcessInfo.processInfo.environment
        self.publishesDiscoveryRecord = publishesDiscoveryRecord
            ?? (socketPath == AutomationConfig.resolveServerSocketPath(
                environment: ProcessInfo.processInfo.environment
            ))
        self.recoveryPolicy = recoveryPolicy
        self.testHooks = testHooks
        self.commandExecutor = AutomationCommandExecutor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService,
            automationConfig: automationConfig
        )
        try startListening()
    }

    deinit {
        stopListening()
    }

    static func recommendedSocketPath(
        preferredSocketPath: String,
        environment: [String: String],
        processID: Int32 = getpid(),
        fileManager: FileManager = .default
    ) -> String {
        let runtimePreferredSocketPath = ToasttyRuntimePaths.resolve(environment: environment)
            .automationSocketFileURL?
            .path
        guard preferredSocketPath == runtimePreferredSocketPath else {
            return preferredSocketPath
        }

        switch socketBindingAvailability(for: preferredSocketPath, fileManager: fileManager) {
        case .live:
            return alternateSocketPath(for: preferredSocketPath, processID: processID)
        case .available, .stale, .inspectionFailed:
            return preferredSocketPath
        }
    }

    static func alternateSocketPath(
        for preferredSocketPath: String,
        processID: Int32 = getpid()
    ) -> String {
        let preferredSocketURL = URL(fileURLWithPath: preferredSocketPath, isDirectory: false)
        return preferredSocketURL.deletingLastPathComponent()
            .appendingPathComponent("events-v1-\(processID).sock", isDirectory: false)
            .path
    }

    private func startListening() throws {
        isStopping = false
        let socketURL = URL(fileURLWithPath: socketPath, isDirectory: false)
        let directoryURL = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        _ = chmod(directoryURL.path, 0o700)

        switch Self.socketBindingAvailability(for: socketPath) {
        case .available:
            break
        case .stale:
            ToasttyLog.warning(
                "Replacing stale automation socket path",
                category: .automation,
                metadata: socketLogMetadata()
            )
        case .live:
            ToasttyLog.error(
                "Automation socket path is already in use by a live listener",
                category: .automation,
                metadata: socketLogMetadata()
            )
            throw AutomationSocketStartupError.liveSocketPathInUse(socketPath)
        case .inspectionFailed(let errorNumber):
            ToasttyLog.error(
                "Failed to inspect existing automation socket path",
                category: .automation,
                metadata: socketLogMetadata(
                    additional: [
                        "errno": String(errorNumber),
                        "error": socketErrorMessage(for: errorNumber),
                    ]
                )
            )
            throw AutomationSocketStartupError.socketPathInspectionFailed(
                socketPath,
                errorNumber: errorNumber
            )
        }

        // Remove any stale socket left by prior runs.
        _ = unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AutomationSocketError.internalError("socket() failed: \(errno)")
        }
        do {
            try setNonBlocking(fd)
        } catch {
            close(fd)
            throw error
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            close(fd)
            throw AutomationSocketError.invalidPayload("socket path too long: \(socketPath)")
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
        ownsSocketPath = true

        _ = chmod(socketPath, 0o600)

        guard listen(fd, SOMAXCONN) == 0 else {
            close(fd)
            throw AutomationSocketError.internalError("listen() failed: \(errno)")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections(listenFD: fd)
        }
        source.setCancelHandler { [weak self] in
            close(fd)
            guard let self else { return }
            if self.listenFD == fd {
                self.listenFD = -1
            }
            ToasttyLog.info(
                "Automation socket listener source cancelled",
                category: .automation,
                metadata: self.socketLogMetadata(
                    additional: [
                        "cancelled_fd": String(fd),
                        "expected": self.isStopping ? "true" : "false",
                        "recovery_pending": self.pendingRecovery == nil ? "false" : "true",
                    ]
                )
            )
            self.beginPendingRecoveryIfNeeded()
        }

        listenFD = fd
        acceptSource = source
        source.resume()
        let currentRecoveryAttempt = recoveryAttemptCount > 0 ? recoveryAttemptCount : nil
        testHooks.listenerDidStart?(fd, currentRecoveryAttempt)

        ToasttyLog.info(
            "Automation socket listener started",
            category: .automation,
            metadata: socketLogMetadata(
                fileDescriptor: fd,
                additional: [
                    "recovery_attempt": currentRecoveryAttempt.map(String.init) ?? "0",
                ]
            )
        )

        if publishesDiscoveryRecord {
            do {
                try AutomationSocketLocator.writeDiscoveryRecord(
                    socketPath: socketPath,
                    processID: getpid(),
                    environment: processEnvironment
                )
                publishedDiscoveryRecord = true
            } catch {
                ToasttyLog.warning(
                    "Failed to write automation socket discovery record",
                    category: .automation,
                    metadata: socketLogMetadata(
                        fileDescriptor: fd,
                        additional: ["error": error.localizedDescription]
                    )
                )
            }
        }
    }

    private func stopListening() {
        isStopping = true
        pendingRecovery = nil
        ToasttyLog.info(
            "Automation socket listener stopping",
            category: .automation,
            metadata: socketLogMetadata(
                fileDescriptor: listenFD >= 0 ? listenFD : nil
            )
        )
        let source = acceptSource
        acceptSource = nil
        if let source {
            listenFD = -1
            source.cancel()
        } else if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        for client in clients.values {
            client.close()
        }
        clients.removeAll()

        if publishedDiscoveryRecord {
            AutomationSocketLocator.removeDiscoveryRecordIfOwned(
                socketPath: socketPath,
                processID: getpid(),
                environment: processEnvironment
            )
            publishedDiscoveryRecord = false
        }
        if ownsSocketPath {
            _ = unlink(socketPath)
            ownsSocketPath = false
        }
    }

    private func acceptConnections(listenFD: Int32) {
        while true {
            let clientFD = nextAcceptedClientFileDescriptor(listenFD: listenFD)
            guard clientFD >= 0 else {
                let errorNumber = errno
                if shouldIgnoreAcceptError(errorNumber) {
                    return
                }
                ToasttyLog.error(
                    "Automation socket accept failed",
                    category: .automation,
                    metadata: socketLogMetadata(
                        fileDescriptor: listenFD >= 0 ? listenFD : nil,
                        additional: [
                            "errno": String(errorNumber),
                            "error": socketErrorMessage(for: errorNumber),
                        ]
                    )
                )
                if shouldRecoverFromAcceptError(errorNumber) {
                    scheduleListenerRecovery(triggeringErrno: errorNumber)
                }
                return
            }

            do {
                try setNonBlocking(clientFD)
            } catch {
                ToasttyLog.warning(
                    "Failed to configure automation socket client",
                    category: .automation,
                    metadata: socketLogMetadata(
                        fileDescriptor: listenFD >= 0 ? listenFD : nil,
                        additional: [
                            "client_fd": String(clientFD),
                            "error": error.localizedDescription,
                        ]
                    )
                )
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

    private func nextAcceptedClientFileDescriptor(listenFD: Int32) -> Int32 {
        if let override = testHooks.acceptOverride?(listenFD) {
            switch override {
            case .useSystemAccept:
                break
            case .fail(let errorNumber):
                errno = errorNumber
                return -1
            }
        }
        return accept(listenFD, nil, nil)
    }

    private func shouldIgnoreAcceptError(_ errorNumber: Int32) -> Bool {
        switch errorNumber {
        case EAGAIN, EWOULDBLOCK, EINTR, ECONNABORTED, EPROTO:
            return true
        default:
            return false
        }
    }

    private func shouldRecoverFromAcceptError(_ errorNumber: Int32) -> Bool {
        switch errorNumber {
        case EBADF, EINVAL, ENOTSOCK, EOPNOTSUPP:
            return true
        default:
            return false
        }
    }

    private func scheduleListenerRecovery(
        triggeringErrno errorNumber: Int32,
        startErrorDescription: String? = nil,
        cancelCurrentListener: Bool = true
    ) {
        guard isStopping == false else { return }
        guard pendingRecovery == nil else { return }

        let nextAttempt = recoveryAttemptCount + 1
        guard let delay = recoveryDelay(forAttempt: nextAttempt) else {
            ToasttyLog.error(
                "Automation socket listener recovery exhausted",
                category: .automation,
                metadata: socketLogMetadata(
                    fileDescriptor: listenFD >= 0 ? listenFD : nil,
                    additional: [
                        "errno": String(errorNumber),
                        "error": socketErrorMessage(for: errorNumber),
                        "attempts": String(recoveryAttemptCount),
                        "last_start_error": startErrorDescription ?? "<none>",
                    ]
                )
            )
            return
        }

        let recovery = PendingListenerRecovery(
            attempt: nextAttempt,
            triggeringErrno: errorNumber,
            delay: delay
        )
        pendingRecovery = recovery
        recoveryAttemptCount = nextAttempt
        testHooks.recoveryDidSchedule?(nextAttempt, errorNumber, delay)

        ToasttyLog.warning(
            "Automation socket listener scheduling recovery",
            category: .automation,
            metadata: socketLogMetadata(
                fileDescriptor: listenFD >= 0 ? listenFD : nil,
                additional: [
                    "errno": String(errorNumber),
                    "error": socketErrorMessage(for: errorNumber),
                    "attempt": String(nextAttempt),
                    "delay_ms": String(Int((delay * 1000).rounded())),
                    "last_start_error": startErrorDescription ?? "<none>",
                ]
            )
        )

        let source = acceptSource
        acceptSource = nil
        if cancelCurrentListener, let source {
            // DispatchSource cancellation is async; the cancel handler closes the old fd
            // before we try to bind the replacement listener on the same socket path.
            listenFD = -1
            source.cancel()
            return
        }

        if cancelCurrentListener, listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        beginPendingRecoveryIfNeeded()
    }

    private func beginPendingRecoveryIfNeeded() {
        guard isStopping == false, let recovery = pendingRecovery else { return }
        pendingRecovery = nil

        if recovery.delay <= 0 {
            queue.async { [weak self] in
                self?.restartListening(after: recovery)
            }
        } else {
            queue.asyncAfter(deadline: .now() + recovery.delay) { [weak self] in
                self?.restartListening(after: recovery)
            }
        }
    }

    private func restartListening(after recovery: PendingListenerRecovery) {
        guard isStopping == false else { return }

        do {
            try startListening()
            recoveryAttemptCount = 0
            ToasttyLog.info(
                "Automation socket listener recovered",
                category: .automation,
                metadata: socketLogMetadata(
                    fileDescriptor: listenFD >= 0 ? listenFD : nil,
                    additional: [
                        "attempt": String(recovery.attempt),
                        "trigger_errno": String(recovery.triggeringErrno),
                        "trigger_error": socketErrorMessage(for: recovery.triggeringErrno),
                    ]
                )
            )
        } catch {
            ToasttyLog.error(
                "Automation socket listener recovery attempt failed",
                category: .automation,
                metadata: socketLogMetadata(
                    fileDescriptor: listenFD >= 0 ? listenFD : nil,
                    additional: [
                        "attempt": String(recovery.attempt),
                        "trigger_errno": String(recovery.triggeringErrno),
                        "trigger_error": socketErrorMessage(for: recovery.triggeringErrno),
                        "start_error": error.localizedDescription,
                    ]
                )
            )
            scheduleListenerRecovery(
                triggeringErrno: recovery.triggeringErrno,
                startErrorDescription: error.localizedDescription,
                cancelCurrentListener: false
            )
        }
    }

    private func recoveryDelay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt > 0, attempt <= recoveryPolicy.retryDelays.count else {
            return nil
        }
        return recoveryPolicy.retryDelays[attempt - 1]
    }

    private func socketLogMetadata(
        fileDescriptor: Int32? = nil,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "socket_path": socketPath,
            "pid": String(getpid()),
            "publishes_discovery_record": publishesDiscoveryRecord ? "true" : "false",
        ]
        if let fileDescriptor, fileDescriptor >= 0 {
            metadata["listen_fd"] = String(fileDescriptor)
        }
        for (key, value) in additional {
            metadata[key] = value
        }
        return metadata
    }

    private func socketErrorMessage(for errorNumber: Int32) -> String {
        String(cString: strerror(errorNumber))
    }

    private static func socketBindingAvailability(
        for socketPath: String,
        fileManager: FileManager = .default
    ) -> AutomationSocketBindingAvailability {
        guard fileManager.fileExists(atPath: socketPath) else {
            return .available
        }

        for attempt in 0..<Self.liveSocketProbeAttemptCount {
            let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fileDescriptor >= 0 else {
                return .inspectionFailed(errno)
            }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8CString)
            let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count <= maxPathLength else {
                close(fileDescriptor)
                return .inspectionFailed(ENAMETOOLONG)
            }

            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
                pathBytes.withUnsafeBytes { source in
                    if let destinationAddress = buffer.baseAddress, let sourceAddress = source.baseAddress {
                        memcpy(destinationAddress, sourceAddress, pathBytes.count)
                    }
                }
            }

            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    connect(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connectResult == 0 {
                close(fileDescriptor)
                return .live
            }

            let errorNumber = errno
            close(fileDescriptor)
            switch errorNumber {
            case ECONNREFUSED where attempt + 1 < Self.liveSocketProbeAttemptCount:
                usleep(Self.liveSocketProbeRetryDelayMicros)
                continue
            case ECONNREFUSED, ENOENT:
                return .stale
            default:
                return .inspectionFailed(errorNumber)
            }
        }

        return .stale
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
    private let sessionRuntimeStore: SessionRuntimeStore
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let agentLaunchService: AgentLaunchService
    private let automationConfig: AutomationConfig?
    private let startedAt = Date()

    private var stateVersion = 0
    private var currentFixtureName: String
    private var notificationStore = NotificationStore()
    private var sessionUpdateCoalescer = SessionUpdateCoalescer()

    init(
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        sessionRuntimeStore: SessionRuntimeStore,
        focusedPanelCommandController: FocusedPanelCommandController,
        agentLaunchService: AgentLaunchService,
        automationConfig: AutomationConfig?
    ) {
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.sessionRuntimeStore = sessionRuntimeStore
        self.focusedPanelCommandController = focusedPanelCommandController
        self.agentLaunchService = agentLaunchService
        self.automationConfig = automationConfig
        self.currentFixtureName = automationConfig?.fixtureName ?? "default"
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
        } catch let launchError as AgentLaunchError {
            return AutomationResponseEnvelope(
                requestID: responseRequestID,
                ok: false,
                result: nil,
                error: AutomationResponseError(
                    code: "INVALID_PAYLOAD",
                    message: launchError.localizedDescription
                )
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
        case "agent.prepare_managed_launch":
            guard let agentRaw = normalizedOptionalText(payload.string("agent")),
                  let agent = AgentKind(rawValue: agentRaw) else {
                throw AutomationSocketError.invalidPayload("agent must be a lowercase agent ID")
            }
            guard let rawPanelID = normalizedOptionalText(payload.string("panelID")) else {
                throw AutomationSocketError.invalidPayload("panelID is required")
            }
            guard let panelID = UUID(uuidString: rawPanelID) else {
                throw AutomationSocketError.invalidPayload("panelID must be a UUID")
            }

            let argv = payload.stringArray("argv")
            guard argv.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("argv must be a non-empty string array")
            }

            let plan = try agentLaunchService.prepareManagedLaunch(
                ManagedAgentLaunchRequest(
                    agent: agent,
                    panelID: panelID,
                    argv: argv,
                    cwd: normalizedOptionalText(payload.string("cwd"))
                )
            )
            stateVersion += 1
            var response = try automationObject(plan)
            response["stateVersion"] = .int(stateVersion)
            return response

        case "automation.ping":
            return [
                "status": .string("ok"),
                "automationEnabled": .bool(automationConfig != nil),
                "appUptimeMs": .int(Int(Date().timeIntervalSince(startedAt) * 1000)),
                "protocolVersion": .string("1.0"),
            ]

        case "automation.reset":
            try requireAutomationMode(for: command)
            store.replaceState(.bootstrap())
            currentFixtureName = "default"
            sessionRuntimeStore.reset()
            notificationStore = NotificationStore()
            sessionUpdateCoalescer = SessionUpdateCoalescer()
            stateVersion += 1
            return [
                "stateVersion": .int(stateVersion),
            ]

        case "automation.load_fixture":
            try requireAutomationMode(for: command)
            guard let fixtureName = payload.string("name"), fixtureName.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("name is required")
            }
            let state = try AutomationFixtureLoader.loadRequired(named: fixtureName)
            store.replaceState(state)
            currentFixtureName = fixtureName
            sessionRuntimeStore.reset()
            stateVersion += 1
            return [
                "fixture": .string(fixtureName),
                "stateVersion": .int(stateVersion),
            ]

        case "automation.perform_action":
            try requireAutomationMode(for: command)
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
            try requireAutomationMode(for: command)
            guard let text = payload.string("text") else {
                throw AutomationSocketError.invalidPayload("text is required")
            }
            if payload["waitForSurfaceMs"] != nil {
                throw AutomationSocketError.invalidPayload("waitForSurfaceMs is deprecated; use allowUnavailable=true with client-side retry")
            }
            let submit = payload.bool("submit") ?? false
            let allowUnavailable = payload.bool("allowUnavailable") ?? false
            let resolved = try resolveTerminalTarget(payload: payload)
            if terminalRuntimeRegistry.sendText(text, submit: submit, panelID: resolved.panelID) {
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
            try requireAutomationMode(for: command)
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
            try requireAutomationMode(for: command)
            let resolved = try resolveTerminalTarget(payload: payload)
            guard let text = terminalRuntimeRegistry.readVisibleText(panelID: resolved.panelID) else {
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

        case "automation.launch_agent":
            try requireAutomationMode(for: command)
            guard let profileID = normalizedOptionalText(payload.string("profileID"))
                ?? normalizedOptionalText(payload.string("agent")) else {
                throw AutomationSocketError.invalidPayload("profileID is required")
            }

            let panelID = payload.uuid("panelID")
            let workspaceID = payload.uuid("workspaceID")
            let result = try agentLaunchService.launch(
                profileID: profileID,
                workspaceID: workspaceID,
                panelID: panelID
            )
            stateVersion += 1
            var response: [String: AutomationJSONValue] = [
                "profileID": .string(result.agent.rawValue),
                "agent": .string(result.agent.rawValue),
                "displayName": .string(result.displayName),
                "sessionID": .string(result.sessionID),
                "windowID": .string(result.windowID.uuidString),
                "workspaceID": .string(result.workspaceID.uuidString),
                "panelID": .string(result.panelID.uuidString),
                "command": .string(result.commandLine),
                "stateVersion": .int(stateVersion),
            ]
            if let cwd = result.cwd {
                response["cwd"] = .string(cwd)
            }
            if let repoRoot = result.repoRoot {
                response["repoRoot"] = .string(repoRoot)
            }
            return response

        case "automation.terminal_state":
            try requireAutomationMode(for: command)
            let resolved = try resolveTerminalTarget(payload: payload)
            return try terminalStateSnapshot(
                workspaceID: resolved.workspaceID,
                panelID: resolved.panelID
            )

        case "automation.dump_state":
            try requireAutomationMode(for: command)
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
            try requireAutomationMode(for: command)
            let workspaceID = try resolveWorkspaceID(args: payload)
            return try workspaceSnapshot(workspaceID: workspaceID)

        case "automation.workspace_render_snapshot":
            try requireAutomationMode(for: command)
            let workspaceID = try resolveWorkspaceID(args: payload)
            return try workspaceRenderSnapshot(workspaceID: workspaceID)

        case "automation.capture_screenshot":
            try requireAutomationMode(for: command)
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

    private func requireAutomationMode(for command: String) throws {
        guard automationConfig != nil else {
            throw AutomationSocketError.invalidPayload("\(command) requires automation mode")
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
                throw AutomationSocketError.invalidPayload("agent must be a lowercase agent ID")
            }
            guard let location = locatePanel(panelID) else {
                throw AutomationSocketError.invalidPayload("panelID does not exist")
            }

            sessionRuntimeStore.startSession(
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
                "sessionID": .string(sessionID),
                "stateVersion": .int(stateVersion),
            ]

        case "session.status":
            guard let sessionID = event.sessionID, sessionID.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("sessionID is required")
            }
            _ = try resolveActiveSession(
                sessionID: sessionID,
                rawPanelID: event.panelID
            )
            guard let kindRaw = event.payload.string("kind"),
                  let kind = SessionStatusKind(rawValue: kindRaw) else {
                throw AutomationSocketError.invalidPayload(
                    "kind must be one of: idle, working, needs_approval, ready, error"
                )
            }
            guard let summary = normalizedOptionalText(event.payload.string("summary")) else {
                throw AutomationSocketError.invalidPayload("summary is required")
            }
            let detail = normalizedOptionalText(event.payload.string("detail"))
            sessionRuntimeStore.updateStatus(
                sessionID: sessionID,
                status: SessionStatus(kind: kind, summary: summary, detail: detail),
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
            _ = try resolveActiveSession(
                sessionID: sessionID,
                rawPanelID: event.panelID
            )

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

        case "session.stop":
            guard let sessionID = event.sessionID, sessionID.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("sessionID is required")
            }
            _ = try resolveActiveSession(
                sessionID: sessionID,
                rawPanelID: event.panelID,
                requireLivePanel: false
            )
            flushAllCoalescedUpdates()
            sessionRuntimeStore.stopSession(sessionID: sessionID, at: now)
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
            } else {
                resolvedWorkspaceID = try resolveWorkspaceSelection(args: event.payload).workspaceID
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
        var resolvedWorkspaceID: UUID?
        func workspaceID() throws -> UUID {
            if let resolvedWorkspaceID {
                return resolvedWorkspaceID
            }
            let workspaceID = try resolveWorkspaceID(args: args)
            resolvedWorkspaceID = workspaceID
            return workspaceID
        }

        func profileBinding() throws -> TerminalProfileBinding {
            guard let profileID = args.string("profileID")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  profileID.isEmpty == false else {
                throw AutomationSocketError.invalidPayload("profileID is required")
            }
            return TerminalProfileBinding(profileID: profileID)
        }

        let didMutate: Bool
        switch actionID {
        case "workspace.split.horizontal":
            didMutate = store.send(.splitFocusedSlot(workspaceID: try workspaceID(), orientation: .horizontal))

        case "workspace.split.vertical":
            didMutate = store.send(.splitFocusedSlot(workspaceID: try workspaceID(), orientation: .vertical))

        case "workspace.split.right":
            didMutate = store.send(.splitFocusedSlotInDirection(workspaceID: try workspaceID(), direction: .right))

        case "workspace.split.down":
            didMutate = store.send(.splitFocusedSlotInDirection(workspaceID: try workspaceID(), direction: .down))

        case "workspace.split.left":
            didMutate = store.send(.splitFocusedSlotInDirection(workspaceID: try workspaceID(), direction: .left))

        case "workspace.split.up":
            didMutate = store.send(.splitFocusedSlotInDirection(workspaceID: try workspaceID(), direction: .up))

        case "workspace.split.right.with-profile":
            let resolvedWorkspaceID = try workspaceID()
            didMutate = terminalRuntimeRegistry.splitFocusedSlotInDirectionWithTerminalProfile(
                workspaceID: resolvedWorkspaceID,
                direction: .right,
                profileBinding: try profileBinding()
            )

        case "workspace.split.down.with-profile":
            let resolvedWorkspaceID = try workspaceID()
            didMutate = terminalRuntimeRegistry.splitFocusedSlotInDirectionWithTerminalProfile(
                workspaceID: resolvedWorkspaceID,
                direction: .down,
                profileBinding: try profileBinding()
            )

        case "workspace.close-focused-panel":
            didMutate = focusedPanelCommandController.closeFocusedPanel(in: try workspaceID()).didMutateState

        case "workspace.focus-slot.previous":
            didMutate = store.send(.focusSlot(workspaceID: try workspaceID(), direction: .previous))

        case "workspace.focus-slot.next":
            didMutate = store.send(.focusSlot(workspaceID: try workspaceID(), direction: .next))

        case "workspace.focus-slot.left":
            didMutate = store.send(.focusSlot(workspaceID: try workspaceID(), direction: .left))

        case "workspace.focus-slot.right":
            didMutate = store.send(.focusSlot(workspaceID: try workspaceID(), direction: .right))

        case "workspace.focus-slot.up":
            didMutate = store.send(.focusSlot(workspaceID: try workspaceID(), direction: .up))

        case "workspace.focus-slot.down":
            didMutate = store.send(.focusSlot(workspaceID: try workspaceID(), direction: .down))

        case "workspace.focus-panel":
            guard let panelID = args.uuid("panelID") else {
                throw AutomationSocketError.invalidPayload("panelID must be a UUID")
            }
            didMutate = store.send(.focusPanel(workspaceID: try workspaceID(), panelID: panelID))

        case "workspace.resize-split.left":
            didMutate = store.send(
                .resizeFocusedSlotSplit(
                    workspaceID: try workspaceID(),
                    direction: .left,
                    amount: max(args.int("amount") ?? 1, 1)
                )
            )

        case "workspace.resize-split.right":
            didMutate = store.send(
                .resizeFocusedSlotSplit(
                    workspaceID: try workspaceID(),
                    direction: .right,
                    amount: max(args.int("amount") ?? 1, 1)
                )
            )

        case "workspace.resize-split.up":
            didMutate = store.send(
                .resizeFocusedSlotSplit(
                    workspaceID: try workspaceID(),
                    direction: .up,
                    amount: max(args.int("amount") ?? 1, 1)
                )
            )

        case "workspace.resize-split.down":
            didMutate = store.send(
                .resizeFocusedSlotSplit(
                    workspaceID: try workspaceID(),
                    direction: .down,
                    amount: max(args.int("amount") ?? 1, 1)
                )
            )

        case "workspace.equalize-splits":
            didMutate = store.send(.equalizeLayoutSplits(workspaceID: try workspaceID()))

        case "topbar.toggle.diff":
            didMutate = store.send(.toggleAuxPanel(workspaceID: try workspaceID(), kind: .diff))

        case "topbar.toggle.markdown":
            didMutate = store.send(.toggleAuxPanel(workspaceID: try workspaceID(), kind: .markdown))

        case "topbar.toggle.scratchpad":
            didMutate = store.send(.toggleAuxPanel(workspaceID: try workspaceID(), kind: .scratchpad))

        case "topbar.toggle.focused-panel":
            didMutate = store.send(.toggleFocusedPanelMode(workspaceID: try workspaceID()))

        case "app.font.increase":
            didMutate = store.send(.increaseGlobalTerminalFont)

        case "app.font.decrease":
            didMutate = store.send(.decreaseGlobalTerminalFont)

        case "app.font.reset":
            didMutate = store.send(.resetGlobalTerminalFont)

        case "sidebar.workspaces.new":
            let windowID = try resolveWindowID(args: args)
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
    private func resolveWorkspaceSelection(args: [String: AutomationJSONValue]) throws -> WindowWorkspaceSelection {
        if let rawWorkspaceID = args.string("workspaceID") {
            guard let workspaceID = UUID(uuidString: rawWorkspaceID) else {
                throw AutomationSocketError.invalidPayload("workspaceID must be a UUID")
            }
            guard let selection = store.state.workspaceSelection(containingWorkspaceID: workspaceID) else {
                throw AutomationSocketError.invalidPayload("workspaceID does not exist")
            }
            if let rawWindowID = args.string("windowID") {
                guard let windowID = UUID(uuidString: rawWindowID) else {
                    throw AutomationSocketError.invalidPayload("windowID must be a UUID")
                }
                guard selection.windowID == windowID else {
                    throw AutomationSocketError.invalidPayload("workspaceID does not belong to windowID")
                }
            }
            return selection
        }

        if let rawWindowID = args.string("windowID") {
            guard let windowID = UUID(uuidString: rawWindowID) else {
                throw AutomationSocketError.invalidPayload("windowID must be a UUID")
            }
            guard let selection = store.state.workspaceSelection(in: windowID) else {
                throw AutomationSocketError.invalidPayload("windowID does not exist")
            }
            return selection
        }

        if let selection = store.state.soleWorkspaceSelection() {
            return selection
        }

        if store.state.windows.isEmpty {
            throw AutomationSocketError.invalidPayload("no window is available")
        }

        throw AutomationSocketError.invalidPayload("workspaceID or windowID is required when multiple windows exist")
    }

    @MainActor
    private func resolveWorkspaceID(args: [String: AutomationJSONValue]) throws -> UUID {
        try resolveWorkspaceSelection(args: args).workspaceID
    }

    @MainActor
    private func resolveWindowID(args: [String: AutomationJSONValue]) throws -> UUID {
        if let rawWindowID = args.string("windowID") {
            guard let windowID = UUID(uuidString: rawWindowID) else {
                throw AutomationSocketError.invalidPayload("windowID must be a UUID")
            }
            guard store.state.window(id: windowID) != nil else {
                throw AutomationSocketError.invalidPayload("windowID does not exist")
            }
            return windowID
        }

        if store.state.windows.count == 1, let windowID = store.state.windows.first?.id {
            return windowID
        }

        if store.state.windows.isEmpty {
            throw AutomationSocketError.invalidPayload("no window is available")
        }

        throw AutomationSocketError.invalidPayload("windowID is required when multiple windows exist")
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

        for leaf in workspace.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            if let panelState = workspace.panels[panelID], case .terminal = panelState {
                return (workspaceID, panelID)
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
                sessionRegistry: sessionRuntimeStore.sessionRegistry,
                notifications: notificationStore.notifications
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
            "profileID": terminalState.profileBinding.map { .string($0.profileID) } ?? .null,
        ]
    }

    @MainActor
    private func workspaceSnapshot(workspaceID: UUID) throws -> [String: AutomationJSONValue] {
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }

        let slotInfos = workspace.layoutTree.allSlotInfos
        let slotIDs = slotInfos.map { AutomationJSONValue.string($0.slotID.uuidString) }
        let slotPanelIDs = slotInfos.map { AutomationJSONValue.string($0.panelID.uuidString) }
        let slotMappings = slotInfos.map { slotInfo in
            AutomationJSONValue.object([
                "slotID": .string(slotInfo.slotID.uuidString),
                "panelID": .string(slotInfo.panelID.uuidString),
            ])
        }
        let rootSplitRatio: AutomationJSONValue
        switch workspace.layoutTree {
        case .split(_, _, let ratio, _, _):
            rootSplitRatio = .double(ratio)
        case .slot:
            rootSplitRatio = .null
        }

        return [
            "workspaceID": .string(workspaceID.uuidString),
            "slotCount": .int(slotInfos.count),
            "panelCount": .int(workspace.panels.count),
            "focusedPanelID": workspace.focusedPanelID.map { .string($0.uuidString) } ?? .null,
            "rootSplitRatio": rootSplitRatio,
            "slotIDs": .array(slotIDs),
            "slotPanelIDs": .array(slotPanelIDs),
            "slotMappings": .array(slotMappings),
            "layoutSignature": .string(layoutSignature(for: workspace)),
        ]
    }

    @MainActor
    private func workspaceRenderSnapshot(workspaceID: UUID) throws -> [String: AutomationJSONValue] {
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw AutomationSocketError.invalidPayload("workspaceID does not exist")
        }

        let terminalPanelIDs: [UUID] = workspace.layoutTree.allSlotInfos.compactMap { slotInfo in
            let panelID = slotInfo.panelID
            guard let panelState = workspace.panels[panelID] else {
                return nil
            }
            if case .terminal = panelState {
                return panelID
            }
            return nil
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
                "hostLifecycleState": .string(snapshot.lifecycleState.automationLabel),
                "hostAttachmentID": snapshot.lifecycleState.attachmentToken.map { .string($0.rawValue.uuidString) } ?? .null,
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

    private func layoutSignature(for workspace: WorkspaceState) -> String {
        let slotSignature = workspace.layoutTree.allSlotInfos
            .map { "\($0.slotID.uuidString):\($0.panelID.uuidString)" }
            .joined(separator: ",")
        let focusSignature = workspace.focusedPanelID?.uuidString ?? "nil"
        let rootSignature: String
        switch workspace.layoutTree {
        case .split(_, _, let ratio, _, _):
            rootSignature = String(format: "%.6f", ratio)
        case .slot:
            rootSignature = "slot"
        }
        return "focus=\(focusSignature);root=\(rootSignature);slots=\(slotSignature)"
    }

    private func screenshotURL(fixture: String, step: String) throws -> URL {
        let fixtureComponent = sanitizedPathComponent(fixture)
        let stepComponent = sanitizedPathComponent(step)
        let directory = try ensureRunArtifactDirectory().appendingPathComponent(fixtureComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(stepComponent).png")
    }

    private func ensureRunArtifactDirectory() throws -> URL {
        guard let automationConfig else {
            throw AutomationSocketError.invalidPayload("artifacts require automation mode")
        }

        let rootDirectory = URL(
            fileURLWithPath: automationConfig.artifactsDirectory ?? FileManager.default.temporaryDirectory.path,
            isDirectory: true
        )
            .appendingPathComponent("ui", isDirectory: true)
            .appendingPathComponent(sanitizedPathComponent(automationConfig.runID), isDirectory: true)
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

    private func normalizedOptionalText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func automationObject<T: Encodable>(_ value: T) throws -> [String: AutomationJSONValue] {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode([String: AutomationJSONValue].self, from: data)
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
        guard let selection = store.state.selectedWorkspaceSelection() else {
            return false
        }
        guard selection.workspace.focusedPanelID == panelID else {
            return false
        }
        return selection.workspace.layoutTree.slotContaining(panelID: panelID) != nil
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
            sessionRuntimeStore.updateFiles(
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
            sessionRuntimeStore.updateFiles(
                sessionID: update.sessionID,
                files: update.files,
                cwd: update.cwd,
                repoRoot: update.repoRoot,
                at: now
            )
        }
    }

    @MainActor
    private func resolveActiveSession(
        sessionID: String,
        rawPanelID: String?,
        requireLivePanel: Bool = true
    ) throws -> SessionRecord {
        let parsedPanelID = rawPanelID.flatMap(UUID.init(uuidString:))
        guard let record = sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID) else {
            ToasttyLog.warning(
                "Rejected session event for inactive session",
                category: .automation,
                metadata: [
                    "session_id": sessionID,
                    "raw_panel_id": rawPanelID ?? "none",
                    "parsed_panel_id": parsedPanelID?.uuidString ?? "none",
                    "active_session_for_panel": parsedPanelID
                        .flatMap { sessionRuntimeStore.sessionRegistry.activeSession(for: $0)?.sessionID }
                        ?? "none",
                    "require_live_panel": requireLivePanel ? "true" : "false",
                ]
            )
            throw AutomationSocketError.invalidPayload("sessionID does not identify an active session")
        }

        if let panelID = try parsePanelID(rawPanelID) {
            guard panelID == record.panelID else {
                ToasttyLog.warning(
                    "Rejected session event with mismatched panel",
                    category: .automation,
                    metadata: [
                        "session_id": sessionID,
                        "agent": record.agent.rawValue,
                        "expected_panel_id": record.panelID.uuidString,
                        "provided_panel_id": panelID.uuidString,
                        "workspace_id": record.workspaceID.uuidString,
                    ]
                )
                throw AutomationSocketError.invalidPayload("panelID does not match active session")
            }
        }

        if requireLivePanel {
            guard locatePanel(record.panelID) != nil else {
                ToasttyLog.warning(
                    "Rejected session event for missing panel",
                    category: .automation,
                    metadata: [
                        "session_id": sessionID,
                        "agent": record.agent.rawValue,
                        "panel_id": record.panelID.uuidString,
                        "workspace_id": record.workspaceID.uuidString,
                    ]
                )
                throw AutomationSocketError.invalidPayload("panelID does not exist")
            }
        }

        return record
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

private extension AutomationEventEnvelope {
    func requiredPanelID() throws -> UUID {
        guard let panelID,
              let uuid = UUID(uuidString: panelID) else {
            throw AutomationSocketError.invalidPayload("panelID must be a UUID")
        }
        return uuid
    }
}

private func parsePanelID(_ panelID: String?) throws -> UUID? {
    guard let panelID else { return nil }
    guard let uuid = UUID(uuidString: panelID) else {
        throw AutomationSocketError.invalidPayload("panelID must be a UUID")
    }
    return uuid
}

private struct AutomationRuntimeStateDump: Encodable, Sendable {
    let appState: AppState
    let sessionRegistry: SessionRegistry
    let notifications: [ToasttyNotification]
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
