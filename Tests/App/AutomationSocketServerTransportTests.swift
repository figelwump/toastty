import RemoteProtocol
import Darwin
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerTransportTests: AutomationSocketServerTestSupport {
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
}
