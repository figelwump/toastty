import Darwin
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerTests {
    @Test
    func removedLegacySessionEventsAreRejected() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        for eventType in ["session.progress", "session.needs_input", "session.error"] {
            let response = try sendEvent(type: eventType, socketPath: socketPath)
            #expect(response.ok == false)
            #expect(response.error?.code == "UNKNOWN_EVENT_TYPE")
        }
    }

    @Test
    func sessionStartResponseIncludesSessionID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-123"
        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("sessionID") == sessionID)
    }

    @Test
    func sessionStatusCanResolveActiveSessionWithoutPanelID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-status-only"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("editing 3 files"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("eventType") == "session.status")
    }

    @Test
    func sessionStatusCanResolveActiveSessionForBackgroundTabPanel() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let initialContext = try await MainActor.run {
            let selection = try #require(server.store.state.selectedWorkspaceSelection())
            return (
                workspaceID: selection.workspaceID,
                originalTabID: try #require(selection.workspace.resolvedSelectedTabID),
                panelID: try #require(selection.workspace.focusedPanelID)
            )
        }

        let sessionID = "sess-background-tab"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: initialContext.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        _ = try await MainActor.run {
            #expect(server.store.send(.createWorkspaceTab(workspaceID: initialContext.workspaceID, seed: nil)))
            let workspace = try #require(server.store.state.workspacesByID[initialContext.workspaceID])
            let backgroundTabID = try #require(workspace.resolvedSelectedTabID)
            #expect(backgroundTabID != initialContext.originalTabID)
            return backgroundTabID
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("editing in background tab"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let activeSession = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)
        }
        #expect(activeSession?.status?.kind == .working)
    }

    @Test
    func sessionStatusRejectsMismatchedPanelIDForActiveSession() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-mismatch"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                panelID: UUID().uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("editing 3 files"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok == false)
        #expect(response.error?.code == "INVALID_PAYLOAD")
        #expect(response.error?.message == "panelID does not match active session")
    }

    @Test
    func sessionUpdateFilesCanResolveActiveSessionWithoutPanelID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-files-only"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.update_files",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "files": .array([.string("/tmp/a.swift")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("eventType") == "session.update_files")
        #expect(response.result?.int("queuedFiles") == 1)
    }

    @Test
    func sessionStopCanResolveActiveSessionWithoutPanelID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-stop-only"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.stop",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [:]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("eventType") == "session.stop")
    }

    @Test
    func automationLaunchAgentUsesSharedLaunchService() async throws {
        let socketPath = temporarySocketPath()
        let terminalRouter = TestTerminalCommandRouter()
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                automationConfig: AutomationConfig(
                    runID: "launch-agent",
                    fixtureName: nil,
                    artifactsDirectory: nil,
                    socketPath: socketPath,
                    disableAnimations: true,
                    fixedLocaleIdentifier: nil,
                    fixedTimeZoneIdentifier: nil
                ),
                terminalCommandRouter: terminalRouter
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "automation.launch_agent",
                payload: [
                    "profileID": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let sessionID = try #require(response.result?.string("sessionID"))
        let command = try #require(response.result?.string("command"))
        #expect(response.result?.string("profileID") == AgentKind.codex.rawValue)
        #expect(response.result?.string("agent") == AgentKind.codex.rawValue)
        #expect(response.result?.string("panelID") == server.panelID.uuidString)
        #expect(response.result?.string("workspaceID") == server.workspaceID.uuidString)
        #expect(command.contains("TOASTTY_SESSION_ID=\(sessionID)"))
        #expect(command.contains("TOASTTY_PANEL_ID=\(server.panelID.uuidString)"))
        #expect(command.contains("codex -c "))
        #expect(command.contains("notify=["))
        #expect(command.contains("codex-notify.sh"))
        let activeAgent = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.agent
        }
        #expect(activeAgent == .codex)
    }

    @Test
    func secondServerCannotStealALiveSocketPath() async {
        let socketPath = temporarySocketPath()
        let firstServer: (
            server: AutomationSocketServer,
            store: AppStore,
            panelID: UUID,
            workspaceID: UUID,
            sessionRuntimeStore: SessionRuntimeStore
        )
        do {
            firstServer = try await MainActor.run {
                try makeServer(socketPath: socketPath)
            }
        } catch {
            Issue.record("failed to start first server: \(error)")
            return
        }
        defer {
            withExtendedLifetime(firstServer.server) {}
        }

        do {
            try waitForSocket(at: socketPath)
        } catch {
            Issue.record("first server never became reachable: \(error)")
            return
        }

        do {
            _ = try await MainActor.run {
                _ = try makeServer(socketPath: socketPath)
            }
            Issue.record("second server unexpectedly started on an occupied socket path")
        } catch let startupError as AutomationSocketStartupError {
            #expect(startupError == .liveSocketPathInUse(socketPath))
        } catch {
            Issue.record("second server failed with unexpected error: \(error)")
        }

        do {
            let response = try sendEvent(
                AutomationEventEnvelope(
                    eventType: "session.start",
                    sessionID: "sess-still-live",
                    panelID: firstServer.panelID.uuidString,
                    requestID: UUID().uuidString,
                    payload: [
                        "agent": .string(AgentKind.codex.rawValue),
                    ]
                ),
                socketPath: socketPath
            )
            #expect(response.ok)
        } catch {
            Issue.record("first server stopped responding after second startup attempt: \(error)")
        }
    }

    @Test
    func recommendedSocketPathFallsBackWhenRuntimePreferredPathIsLive() throws {
        let runtimeSocketEnvironment = try makeRuntimeSocketEnvironment()
        defer {
            try? FileManager.default.removeItem(at: runtimeSocketEnvironment.rootURL)
        }
        let environment = runtimeSocketEnvironment.environment
        let runtimePaths = ToasttyRuntimePaths.resolve(environment: environment)
        let preferredSocketPath = try #require(runtimePaths.automationSocketFileURL?.path)
        let liveSocketFD = try bindAndListenRawSocket(socketPath: preferredSocketPath)
        defer {
            close(liveSocketFD)
            try? FileManager.default.removeItem(atPath: preferredSocketPath)
        }

        let resolvedSocketPath = AutomationSocketServer.recommendedSocketPath(
            preferredSocketPath: preferredSocketPath,
            environment: environment,
            processID: 4242
        )

        #expect(resolvedSocketPath != preferredSocketPath)
        #expect(resolvedSocketPath.hasSuffix("/events-v1-4242.sock"))
    }

    @Test
    func staleSocketFileCanBeReplacedDuringStartup() async throws {
        let socketPath = temporarySocketPath()
        let staleSocketFD = try bindAndListenRawSocket(socketPath: socketPath)
        close(staleSocketFD)

        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: "sess-stale-replaced",
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok)
    }

    @Test
    func fatalAcceptErrorsRestartTheListenerOnTheSameSocketPath() async throws {
        let socketPath = temporarySocketPath()
        let probe = ListenerRecoveryProbe()
        let acceptOverride = OneShotAcceptOverride(errorNumber: EBADF)
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                recoveryPolicy: AutomationSocketServerRecoveryPolicy(retryDelays: [0]),
                testHooks: AutomationSocketServerTestHooks(
                    acceptOverride: { _ in acceptOverride.nextResult() },
                    listenerDidStart: { _, recoveryAttempt in
                        probe.recordListenerStart(recoveryAttempt: recoveryAttempt)
                    },
                    recoveryDidSchedule: { attempt, errorNumber, delay in
                        probe.recordRecoverySchedule(attempt: attempt, errorNumber: errorNumber, delay: delay)
                    }
                )
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)
        try connectAndClose(socketPath: socketPath)
        try waitUntil("listener recovery was scheduled") {
            probe.recoverySchedulesSnapshot().count == 1
        }
        try waitUntil("listener restarted after fatal accept error") {
            probe.listenerStartsSnapshot().count >= 2
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: "sess-recovery",
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok)
        let recoverySchedules = probe.recoverySchedulesSnapshot()
        let listenerStarts = probe.listenerStartsSnapshot()
        #expect(recoverySchedules.map { $0.attempt } == [1])
        #expect(recoverySchedules.map { $0.errorNumber } == [EBADF])
        #expect(listenerStarts == [nil, 1])
    }

    @Test
    func transientAcceptErrorsDoNotRestartTheListener() async throws {
        let socketPath = temporarySocketPath()
        let probe = ListenerRecoveryProbe()
        let acceptOverride = OneShotAcceptOverride(errorNumber: EINTR)
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                recoveryPolicy: AutomationSocketServerRecoveryPolicy(retryDelays: [0]),
                testHooks: AutomationSocketServerTestHooks(
                    acceptOverride: { _ in acceptOverride.nextResult() },
                    listenerDidStart: { _, recoveryAttempt in
                        probe.recordListenerStart(recoveryAttempt: recoveryAttempt)
                    },
                    recoveryDidSchedule: { attempt, errorNumber, delay in
                        probe.recordRecoverySchedule(attempt: attempt, errorNumber: errorNumber, delay: delay)
                    }
                )
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)
        try connectAndClose(socketPath: socketPath)
        try await Task.sleep(for: .milliseconds(100))

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: "sess-transient",
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok)
        #expect(probe.recoverySchedulesSnapshot().isEmpty)
        #expect(probe.listenerStartsSnapshot() == [nil])
    }

    private func temporarySocketPath() -> String {
        "/tmp/toastty-tests-\(UUID().uuidString.prefix(8)).sock"
    }

    private func waitForSocket(at socketPath: String) throws {
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
    private func makeServer(
        socketPath: String,
        automationConfig: AutomationConfig? = nil,
        terminalCommandRouter: (any TerminalCommandRouting)? = nil,
        recoveryPolicy: AutomationSocketServerRecoveryPolicy = .default,
        testHooks: AutomationSocketServerTestHooks = .disabled
    ) throws -> (
        server: AutomationSocketServer,
        store: AppStore,
        panelID: UUID,
        workspaceID: UUID,
        sessionRuntimeStore: SessionRuntimeStore
    ) {
        let store = AppStore(persistTerminalFontPreference: false)
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let agentCatalogProvider = TestAgentCatalogProvider()
        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: terminalRuntimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
        )

        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let workspaceID = workspace.id
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalCommandRouter ?? terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { socketPath }
        )
        let server = try AutomationSocketServer(
            socketPath: socketPath,
            automationConfig: automationConfig,
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService,
            recoveryPolicy: recoveryPolicy,
            testHooks: testHooks
        )
        return (server, store, panelID, workspaceID, sessionRuntimeStore)
    }

    private func sendEvent(type eventType: String, socketPath: String) throws -> AutomationResponseEnvelope {
        try sendEvent(
            AutomationEventEnvelope(
                eventType: eventType,
                requestID: UUID().uuidString,
                payload: [:]
            ),
            socketPath: socketPath
        )
    }

    private func sendEvent(_ request: AutomationEventEnvelope, socketPath: String) throws -> AutomationResponseEnvelope {
        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        let responseData = try send(payload, to: socketPath)
        return try JSONDecoder().decode(AutomationResponseEnvelope.self, from: responseData)
    }

    private func sendRequest(_ request: AutomationRequestEnvelope, socketPath: String) throws -> AutomationResponseEnvelope {
        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        let responseData = try send(payload, to: socketPath)
        return try JSONDecoder().decode(AutomationResponseEnvelope.self, from: responseData)
    }

    private func send(_ payload: Data, to socketPath: String) throws -> Data {
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

    private func connectAndClose(socketPath: String) throws {
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

    private func bindAndListenRawSocket(socketPath: String) throws -> Int32 {
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

    private func makeRuntimeSocketEnvironment() throws -> (rootURL: URL, environment: [String: String]) {
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

    private func makeShortTemporaryDirectory(prefix: String) throws -> URL {
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

    private func waitUntil(
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

private enum SocketTestError: Error {
    case missingResponseTerminator
    case shortWrite
    case socket(Int32)
    case socketPathTooLong
    case timeoutWaitingForSocket
    case timeout(String)
}

private final class ListenerRecoveryProbe: @unchecked Sendable {
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

private final class OneShotAcceptOverride: @unchecked Sendable {
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
