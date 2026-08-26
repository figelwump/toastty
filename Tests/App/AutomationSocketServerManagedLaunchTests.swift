import RemoteProtocol
import Darwin
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerManagedLaunchTests: AutomationSocketServerTestSupport {
    @Test
    func prepareManagedLaunchReturnsStructuredPlan() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let initialHasEverLaunchedAgent = await MainActor.run {
            server.store.hasEverLaunchedAgent
        }
        #expect(initialHasEverLaunchedAgent == false)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "argv": .array([.string("codex"), .string("--model"), .string("gpt-5.4")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let sessionID = try #require(response.result?.string("sessionID"))
        #expect(response.result?.string("agent") == AgentKind.codex.rawValue)
        #expect(response.result?.string("panelID") == server.panelID.uuidString)
        #expect(response.result?.string("workspaceID") == server.workspaceID.uuidString)
        #expect(response.result?.string("cwd") == "/tmp/repo")
        guard case .array(let argv)? = response.result?["argv"] else {
            Issue.record("expected argv array in response")
            return
        }
        let argvStrings = argv.compactMap { value -> String? in
            guard case .string(let stringValue) = value else { return nil }
            return stringValue
        }
        #expect(argvStrings.count == 5)
        #expect(argvStrings[0] == "codex")
        #expect(argvStrings[1] == "-c")
        #expect(argvStrings[2].contains("notify=[\"/bin/sh\",\""))
        #expect(argvStrings[2].contains("codex-notify.sh"))
        #expect(argvStrings[3] == "--model")
        #expect(argvStrings[4] == "gpt-5.4")
        guard case .object(let environment)? = response.result?["environment"] else {
            Issue.record("expected environment object in response")
            return
        }
        #expect(environment["TOASTTY_SESSION_ID"] == .string(sessionID))
        #expect(environment["TOASTTY_PANEL_ID"] == .string(server.panelID.uuidString))
        #expect(environment["TOASTTY_SOCKET_PATH"] == .string(socketPath))
        #expect(environment["TOASTTY_CWD"] == .string("/tmp/repo"))
        let hasEverLaunchedAgent = await MainActor.run {
            server.store.hasEverLaunchedAgent
        }
        #expect(hasEverLaunchedAgent)
    }

    @Test
    func prepareManagedLaunchWithLiveCallerStampsParentSessionID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let callerSessionID = "caller-live"
        try await MainActor.run {
            server.sessionRuntimeStore.startSession(
                sessionID: callerSessionID,
                agent: .claude,
                panelID: server.panelID,
                windowID: try #require(server.store.state.windows.first?.id),
                workspaceID: server.workspaceID,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: Date(timeIntervalSince1970: 2_000)
            )
        }

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                callerSessionID: callerSessionID,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "argv": .array([.string("codex")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let childSessionID = try #require(response.result?.string("sessionID"))
        let parentSessionID = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[childSessionID]?.parentSessionID
        }
        #expect(parentSessionID == callerSessionID)
    }

    @Test
    func prepareManagedLaunchWithoutCallerDoesNotStampParentSessionID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "argv": .array([.string("codex")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let childSessionID = try #require(response.result?.string("sessionID"))
        let parentSessionID = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[childSessionID]?.parentSessionID
        }
        #expect(parentSessionID == nil)
    }

    @Test
    func prepareManagedLaunchWithStoppedCallerDoesNotStampParentSessionID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let callerSessionID = "caller-stopped"
        try await MainActor.run {
            let now = Date(timeIntervalSince1970: 2_100)
            server.sessionRuntimeStore.startSession(
                sessionID: callerSessionID,
                agent: .claude,
                panelID: server.panelID,
                windowID: try #require(server.store.state.windows.first?.id),
                workspaceID: server.workspaceID,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: now
            )
            server.sessionRuntimeStore.stopSession(
                sessionID: callerSessionID,
                at: now.addingTimeInterval(1)
            )
        }

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                callerSessionID: callerSessionID,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "argv": .array([.string("codex")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let childSessionID = try #require(response.result?.string("sessionID"))
        let parentSessionID = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[childSessionID]?.parentSessionID
        }
        #expect(parentSessionID == nil)
    }

    @Test
    func prepareManagedLaunchInteractivePreflightReturnsPendingWithoutStartingSession() async throws {
        let socketPath = temporarySocketPath()
        let missingStatus = codexHookInstallStatus(state: .notInstalled)
        let presentedWindowID = CapturedWindowID()
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                codexStatusHooksPreflightProvider: { _ in .needsSetup(missingStatus) },
                codexStatusHooksWarningPresenter: { _, windowID, _ in
                    presentedWindowID.set(windowID)
                }
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "preflightPolicy": .string(ManagedAgentLaunchPreflightPolicy.interactive.rawValue),
                    "argv": .array([.string("codex")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("kind") == ManagedAgentLaunchPreparationKind.preflightRequired.rawValue)
        let preflight = try #require(response.result?.object("preflight"))
        let token = try #require(preflight.string("token"))
        #expect(preflight.string("agent") == AgentKind.codex.rawValue)
        #expect(preflight.string("panelID") == server.panelID.uuidString)
        let preflightState = await MainActor.run {
            (
                presentedWindowID: presentedWindowID.snapshot(),
                firstWindowID: server.store.state.windows.first?.id,
                sessionCount: server.sessionRuntimeStore.sessionRegistry.sessionsByID.count,
                hasEverLaunchedAgent: server.store.hasEverLaunchedAgent
            )
        }
        #expect(preflightState.presentedWindowID == preflightState.firstWindowID)
        #expect(preflightState.sessionCount == 0)
        #expect(preflightState.hasEverLaunchedAgent == false)

        let decisionResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.managed_launch_preflight_decision",
                payload: ["token": .string(token)]
            ),
            socketPath: socketPath
        )

        #expect(decisionResponse.ok)
        #expect(decisionResponse.result?.string("kind") == ManagedAgentLaunchPreflightDecisionKind.pending.rawValue)
    }

    @Test
    func prepareManagedLaunchCanProceedAfterInteractivePreflightRunAnyway() async throws {
        let socketPath = temporarySocketPath()
        let missingStatus = codexHookInstallStatus(state: .notInstalled)
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                codexStatusHooksPreflightProvider: { _ in .needsSetup(missingStatus) },
                codexStatusHooksWarningPresenter: { _, _, completion in
                    completion(.runAnyway)
                }
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let preflightResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "preflightPolicy": .string(ManagedAgentLaunchPreflightPolicy.interactive.rawValue),
                    "argv": .array([.string("codex")]),
                ]
            ),
            socketPath: socketPath
        )

        let preflight = try #require(preflightResponse.result?.object("preflight"))
        let token = try #require(preflight.string("token"))
        let decisionResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.managed_launch_preflight_decision",
                payload: ["token": .string(token)]
            ),
            socketPath: socketPath
        )
        #expect(decisionResponse.result?.string("kind") == ManagedAgentLaunchPreflightDecisionKind.runAnyway.rawValue)

        let launchResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "preflightPolicy": .string(ManagedAgentLaunchPreflightPolicy.skip.rawValue),
                    "argv": .array([.string("codex")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(launchResponse.ok)
        #expect(launchResponse.result?.string("sessionID") != nil)
        let launchState = await MainActor.run {
            (
                sessionCount: server.sessionRuntimeStore.sessionRegistry.sessionsByID.count,
                hasEverLaunchedAgent: server.store.hasEverLaunchedAgent
            )
        }
        #expect(launchState.sessionCount == 1)
        #expect(launchState.hasEverLaunchedAgent)
    }

    @Test
    func prepareManagedLaunchSetUpHooksInstallsAndContinues() async throws {
        let socketPath = temporarySocketPath()
        let missingStatus = codexHookInstallStatus(state: .notInstalled)
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                codexStatusHooksPreflightProvider: { _ in .needsSetup(missingStatus) },
                codexStatusHooksWarningPresenter: { _, _, completion in
                    completion(.setUpHooks)
                },
                codexStatusHooksInstallAction: {}
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let preflightResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "preflightPolicy": .string(ManagedAgentLaunchPreflightPolicy.interactive.rawValue),
                    "argv": .array([.string("codex")]),
                ]
            ),
            socketPath: socketPath
        )

        let preflight = try #require(preflightResponse.result?.object("preflight"))
        let token = try #require(preflight.string("token"))
        let decisionResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.managed_launch_preflight_decision",
                payload: ["token": .string(token)]
            ),
            socketPath: socketPath
        )

        #expect(decisionResponse.ok)
        #expect(decisionResponse.result?.string("kind") == ManagedAgentLaunchPreflightDecisionKind.runAnyway.rawValue)
    }

    @Test
    func prepareManagedLaunchSetUpHooksReportsInstallFailure() async throws {
        let socketPath = temporarySocketPath()
        let missingStatus = codexHookInstallStatus(state: .notInstalled)
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                codexStatusHooksPreflightProvider: { _ in .needsSetup(missingStatus) },
                codexStatusHooksWarningPresenter: { _, _, completion in
                    completion(.setUpHooks)
                },
                codexStatusHooksInstallAction: {
                    throw NSError(
                        domain: "AutomationSocketServerManagedLaunchTests",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Hooks file is read-only"]
                    )
                }
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let preflightResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "preflightPolicy": .string(ManagedAgentLaunchPreflightPolicy.interactive.rawValue),
                    "argv": .array([.string("codex")]),
                ]
            ),
            socketPath: socketPath
        )

        let preflight = try #require(preflightResponse.result?.object("preflight"))
        let token = try #require(preflight.string("token"))
        let decisionResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.managed_launch_preflight_decision",
                payload: ["token": .string(token)]
            ),
            socketPath: socketPath
        )

        #expect(decisionResponse.ok)
        #expect(decisionResponse.result?.string("kind") == ManagedAgentLaunchPreflightDecisionKind.setUpHooks.rawValue)
        #expect(decisionResponse.result?.string("message")?.contains("Hooks file is read-only") == true)
    }

}
