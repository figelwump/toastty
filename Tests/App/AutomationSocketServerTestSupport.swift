import Darwin
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

protocol AutomationSocketServerTestSupport {}

extension AutomationSocketServerTestSupport {
    func temporarySocketPath() -> String {
        "/tmp/toastty-tests-\(UUID().uuidString.prefix(8)).sock"
    }

    func waitForSocket(at socketPath: String) throws {
        let deadline = Date().addingTimeInterval(1)
        while true {
            guard FileManager.default.fileExists(atPath: socketPath) else {
                guard Date() < deadline else {
                    throw SocketTestError.timeoutWaitingForSocket
                }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            do {
                try connectAndClose(socketPath: socketPath)
                return
            } catch SocketTestError.socket(let errorNumber) where errorNumber == ENOENT || errorNumber == ECONNREFUSED {
                // The path exists but the listener is not yet accepting connections.
            }

            guard Date() < deadline else {
                throw SocketTestError.timeoutWaitingForSocket
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    @MainActor
    func terminalPanelResumeRecord(in store: AppStore, panelID: UUID) -> ManagedAgentResumeRecord? {
        guard let workspace = store.selectedWorkspace,
              case .terminal(let terminalState) = workspace.panels[panelID] else {
            return nil
        }
        return terminalState.resumeRecord
    }

    @MainActor
    func makeServer(
        socketPath: String,
        sessionRuntimeStore: SessionRuntimeStore? = nil,
        automationConfig: AutomationConfig? = nil,
        terminalCommandRouter: (any TerminalCommandRouting)? = nil,
        agentCatalogProvider: (any AgentCatalogProviding)? = nil,
        annotationStyleStore: AnnotationStyleStore? = nil,
        recoveryPolicy: AutomationSocketServerRecoveryPolicy = .default,
        testHooks: AutomationSocketServerTestHooks = .disabled,
        codexStatusTrackingSourceProvider: @escaping @MainActor () -> CodexStatusTrackingSource = {
            .sessionLogFallback(reason: "test")
        },
        codexStatusHooksPreflightProvider: @escaping CodexStatusHooksPreflightProvider = { _ in .ready },
        codexStatusHooksWarningPresenter: @escaping CodexStatusHooksAsyncWarningPresenter = { _, _, completion in
            completion(.cancel)
        },
        codexStatusHooksInstallAction: @escaping CodexStatusHooksInstallAction = {},
        nativeSessionObserverRegistry: (any ManagedAgentNativeSessionObserving)? = nil,
        shouldConfirmPanelClose: Bool? = nil,
        terminalCloseAssessmentProvider: (@MainActor (UUID) -> TerminalCloseConfirmationAssessment?)? = nil,
        localDocumentCloseConfirmationStateProvider: (@MainActor (UUID) -> LocalDocumentCloseConfirmationState?)? = nil,
        runningTerminalCloseConfirmationPresenter: (@MainActor (TerminalCloseConfirmationAssessment) -> Bool)? = nil,
        discardLocalDocumentDraftConfirmationPresenter: (@MainActor (String) -> Bool)? = nil,
        localDocumentSaveInProgressPresenter: (@MainActor (String) -> Void)? = nil
    ) throws -> (
        server: AutomationSocketServer,
        store: AppStore,
        panelID: UUID,
        workspaceID: UUID,
        sessionRuntimeStore: SessionRuntimeStore
    ) {
        let store = AppStore(persistTerminalFontPreference: false)
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        let sessionRuntimeStore = sessionRuntimeStore ?? SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)
        let resolvedAgentCatalogProvider = agentCatalogProvider ?? TestAgentCatalogProvider()
        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: terminalRuntimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            shouldConfirmClose: shouldConfirmPanelClose,
            terminalCloseAssessmentProvider: terminalCloseAssessmentProvider,
            localDocumentCloseConfirmationStateProvider: localDocumentCloseConfirmationStateProvider,
            runningTerminalCloseConfirmationPresenter: runningTerminalCloseConfirmationPresenter,
            discardLocalDocumentDraftConfirmationPresenter: discardLocalDocumentDraftConfirmationPresenter,
            localDocumentSaveInProgressPresenter: localDocumentSaveInProgressPresenter
        )

        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let workspaceID = workspace.id
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalCommandRouter ?? terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: resolvedAgentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { socketPath },
            codexStatusTrackingSourceProvider: codexStatusTrackingSourceProvider,
            nativeSessionObserverRegistry: nativeSessionObserverRegistry
        )
        let server = try AutomationSocketServer(
            socketPath: socketPath,
            automationConfig: automationConfig,
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService,
            annotationStyleStore: annotationStyleStore,
            codexStatusHooksPreflightProvider: codexStatusHooksPreflightProvider,
            codexStatusHooksWarningPresenter: codexStatusHooksWarningPresenter,
            codexStatusHooksInstallAction: codexStatusHooksInstallAction,
            recoveryPolicy: recoveryPolicy,
            testHooks: testHooks
        )
        return (server, store, panelID, workspaceID, sessionRuntimeStore)
    }

    func sendEvent(type eventType: String, socketPath: String) throws -> AutomationResponseEnvelope {
        try sendEvent(
            AutomationEventEnvelope(
                eventType: eventType,
                requestID: UUID().uuidString,
                payload: [:]
            ),
            socketPath: socketPath
        )
    }

    func sendEvent(_ request: AutomationEventEnvelope, socketPath: String) throws -> AutomationResponseEnvelope {
        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        let responseData = try send(payload, to: socketPath)
        return try JSONDecoder().decode(AutomationResponseEnvelope.self, from: responseData)
    }

    func sendRequest(_ request: AutomationRequestEnvelope, socketPath: String) throws -> AutomationResponseEnvelope {
        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        let responseData = try send(payload, to: socketPath)
        return try JSONDecoder().decode(AutomationResponseEnvelope.self, from: responseData)
    }

    func automationSection(from response: AutomationResponseEnvelope) throws -> DiagnosticsAutomationSection {
        let result = try #require(response.result)
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(DiagnosticsAutomationSection.self, from: data)
    }

    func send(_ payload: Data, to socketPath: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketTestError.socket(errno)
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            throw SocketTestError.socketPathTooLong
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
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SocketTestError.socket(errno)
        }

        let bytesWritten = payload.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, payload.count)
        }
        guard bytesWritten == payload.count else {
            throw SocketTestError.shortWrite
        }

        var response = Data()
        var byte: UInt8 = 0
        while true {
            let bytesRead = read(fd, &byte, 1)
            if bytesRead == 0 {
                break
            }
            guard bytesRead > 0 else {
                throw SocketTestError.socket(errno)
            }
            if byte == 0x0A {
                return response
            }
            response.append(byte)
        }

        throw SocketTestError.missingResponseTerminator
    }

    func connectAndClose(socketPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketTestError.socket(errno)
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            throw SocketTestError.socketPathTooLong
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
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SocketTestError.socket(errno)
        }
    }

    func bindAndListenRawSocket(socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketTestError.socket(errno)
        }

        let socketURL = URL(fileURLWithPath: socketPath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            close(fd)
            throw SocketTestError.socketPathTooLong
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
            let errorNumber = errno
            close(fd)
            throw SocketTestError.socket(errorNumber)
        }

        guard listen(fd, SOMAXCONN) == 0 else {
            let errorNumber = errno
            close(fd)
            throw SocketTestError.socket(errorNumber)
        }

        return fd
    }

    func makeRuntimeSocketEnvironment() throws -> (rootURL: URL, environment: [String: String]) {
        let rootURL = try makeShortTemporaryDirectory(prefix: "tts")
        let runtimeHomeURL = rootURL.appendingPathComponent("runtime-home", isDirectory: true)
        let temporaryDirectoryURL = rootURL.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        return (
            rootURL,
            [
                "TOASTTY_RUNTIME_HOME": runtimeHomeURL.path,
                "TMPDIR": temporaryDirectoryURL.path + "/",
            ]
        )
    }

    func makeShortTemporaryDirectory(prefix: String) throws -> URL {
        var template = "/tmp/\(prefix).XXXXXX".utf8CString
        let createdPath = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let baseAddress = buffer.baseAddress, mkdtemp(baseAddress) != nil else {
                return nil
            }
            return String(cString: baseAddress)
        }
        guard let createdPath else {
            throw SocketTestError.socket(errno)
        }
        return URL(fileURLWithPath: createdPath, isDirectory: true)
    }

    func codexHookInstallStatus(
        state: CodexStatusHookInstallState
    ) -> CodexStatusHookInstallStatus {
        let rootURL = URL(fileURLWithPath: "/tmp/toastty-codex-hooks-\(state.rawValue)", isDirectory: true)
        return CodexStatusHookInstallStatus(
            hooksFileURL: rootURL.appendingPathComponent("hooks.json", isDirectory: false),
            forwarderScriptURL: rootURL.appendingPathComponent("forwarder.sh", isDirectory: false),
            state: state
        )
    }

    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 1,
        pollInterval: TimeInterval = 0.01,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false {
            guard Date() < deadline else {
                throw SocketTestError.timeout(description)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }
}

enum SocketTestError: Error {
    case missingResponseTerminator
    case shortWrite
    case socket(Int32)
    case socketPathTooLong
    case timeoutWaitingForSocket
    case timeout(String)
}

final class ListenerRecoveryProbe: @unchecked Sendable {
    private let lock = NSLock()

    private var listenerStarts: [Int?] = []
    private var recoverySchedules: [(attempt: Int, errorNumber: Int32, delay: TimeInterval)] = []

    func recordListenerStart(recoveryAttempt: Int?) {
        lock.lock()
        listenerStarts.append(recoveryAttempt)
        lock.unlock()
    }

    func recordRecoverySchedule(attempt: Int, errorNumber: Int32, delay: TimeInterval) {
        lock.lock()
        recoverySchedules.append((attempt, errorNumber, delay))
        lock.unlock()
    }

    func listenerStartsSnapshot() -> [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return listenerStarts
    }

    func recoverySchedulesSnapshot() -> [(attempt: Int, errorNumber: Int32, delay: TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        return recoverySchedules
    }
}

final class OneShotAcceptOverride: @unchecked Sendable {
    private let lock = NSLock()
    private let errorNumber: Int32
    private var didFire = false

    init(errorNumber: Int32) {
        self.errorNumber = errorNumber
    }

    func nextResult() -> AutomationSocketServerTestHooks.AcceptResult {
        lock.lock()
        defer { lock.unlock() }

        if didFire {
            return .useSystemAccept
        }
        didFire = true
        return .fail(errorNumber)
    }
}

final class CapturedWindowID: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?

    func set(_ value: UUID?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func snapshot() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class SpyNativeSessionObserverRegistry: ManagedAgentNativeSessionObserving {
    private(set) var observations: [ManagedAgentNativeSessionObservationContext] = []
    private(set) var cancelledSessionIDs: [String] = []

    func startObservation(_ observation: ManagedAgentNativeSessionObservationContext) {
        observations.append(observation)
    }

    func cancelObservation(sessionID: String) {
        cancelledSessionIDs.append(sessionID)
    }
}
