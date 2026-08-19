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
        webPanelRuntimeRegistry: WebPanelRuntimeRegistry,
        sessionRuntimeStore: SessionRuntimeStore,
        focusedPanelCommandController: FocusedPanelCommandController,
        agentLaunchService: AgentLaunchService,
        annotationStyleStore: AnnotationStyleStore? = nil,
        inactiveAnnotationUsageCountsProvider: @escaping @MainActor () throws -> [String: Int] = { [:] },
        reloadConfigurationAction: (@MainActor () -> Void)? = nil,
        codexStatusHooksPreflightProvider: @escaping CodexStatusHooksPreflightProvider = AgentLaunchUI.codexStatusHooksPreflightState,
        codexStatusHooksWarningPresenter: @escaping CodexStatusHooksAsyncWarningPresenter = AgentLaunchUI.presentCodexStatusHooksWarningAsync,
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
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService,
            annotationStyleStore: annotationStyleStore,
            inactiveAnnotationUsageCountsProvider: inactiveAnnotationUsageCountsProvider,
            reloadConfigurationAction: reloadConfigurationAction,
            codexStatusHooksPreflightProvider: codexStatusHooksPreflightProvider,
            codexStatusHooksWarningPresenter: codexStatusHooksWarningPresenter,
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
                if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    guard waitUntilWritable(timeoutMilliseconds: 1000) else {
                        break
                    }
                    continue
                }
                break
            }
        }
        close()
    }

    private func waitUntilWritable(timeoutMilliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)

        while true {
            let result = withUnsafeMutablePointer(to: &descriptor) { pointer in
                Darwin.poll(pointer, 1, timeoutMilliseconds)
            }
            if result > 0 {
                return (descriptor.revents & Int16(POLLOUT)) != 0
            }
            if result == 0 {
                return false
            }
            if errno == EINTR {
                continue
            }
            return false
        }
    }
}

enum AutomationIncomingEnvelope: Sendable {
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
