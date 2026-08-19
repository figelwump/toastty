import RemoteProtocol
import Darwin
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerAppControlTests: AutomationSocketServerTestSupport {
    @Test
    func automationLaunchAgentUsesSharedLaunchService() async throws {
        let socketPath = temporarySocketPath()
        let terminalRouter = TestTerminalCommandRouter()
        await MainActor.run {
            terminalRouter.defaultPromptState = .idleAtPrompt
        }
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
    func appControlListsActionsWithoutAutomationMode() async throws {
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
                command: "app_control.list_actions"
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let commands: [AutomationJSONValue]
        switch response.result?["commands"] {
        case .array(let values):
            commands = values
        default:
            Issue.record("expected commands array")
            return
        }
        let ids = commands.compactMap { entry -> String? in
            guard case .object(let object) = entry else {
                return nil
            }
            return object.string("id")
        }
        #expect(ids.contains("window.create"))
        #expect(ids.contains("window.sidebar.toggle"))
        #expect(ids.contains("workspace.move"))
        #expect(ids.contains("workspace.tab.move"))
        #expect(ids.contains("panel.close"))
        #expect(ids.contains("agent.launch"))
        #expect(ids.contains("config.reload") == false)
    }

    @Test
    func appControlRunActionCanToggleSidebarWithoutAutomationMode() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let initialSidebarVisible = await MainActor.run {
            server.store.state.windows.first?.sidebarVisible
        }
        #expect(initialSidebarVisible == true)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "app_control.run_action",
                payload: [
                    "id": .string("window.sidebar.toggle"),
                    "args": .object([:]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.int("stateVersion") == 1)
        let toggledSidebarVisible = await MainActor.run {
            server.store.state.windows.first?.sidebarVisible
        }
        #expect(toggledSidebarVisible == false)
    }

    @Test
    func appControlRunActionRejectsNonObjectArgs() async throws {
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
                command: "app_control.run_action",
                payload: [
                    "id": .string("window.sidebar.toggle"),
                    "args": .string("not-an-object"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok == false)
        #expect(response.error?.code == "INVALID_PAYLOAD")
        #expect(response.error?.message == "args must be an object")
    }

    @Test
    func appControlRunQueryReturnsWorkspaceSnapshotWithoutAutomationMode() async throws {
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
                command: "app_control.run_query",
                payload: [
                    "id": .string("workspace.snapshot"),
                    "args": .object([:]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("workspaceID") == server.workspaceID.uuidString)
        #expect(response.result?.int("panelCount") == 1)
    }

    @Test
    func appControlRunQueryReturnsAnnotationKeysWithoutAutomationMode() async throws {
        let socketPath = temporarySocketPath()
        let runtimeHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-socket-annotation-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: runtimeHomeURL)
        }
        let annotationStyleStore = await MainActor.run {
            AnnotationStyleStore(
                runtimePaths: ToasttyRuntimePaths.resolve(
                    homeDirectoryPath: runtimeHomeURL.path,
                    environment: [ToasttyRuntimePaths.environmentKey: runtimeHomeURL.path]
                )
            )
        }
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                annotationStyleStore: annotationStyleStore
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let setResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "app_control.run_action",
                payload: [
                    "id": .string("workspace.set-annotation"),
                    "args": .object([
                        "workspaceID": .string(server.workspaceID.uuidString),
                        "key": .string("github-pr"),
                        "text": .string("PR #4512"),
                    ]),
                ]
            ),
            socketPath: socketPath
        )
        #expect(setResponse.ok)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "app_control.run_query",
                payload: [
                    "id": .string("annotation.keys"),
                    "args": .object([:]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.stringArray("keys") == ["github-pr"])
    }

    @Test
    func appControlRunActionCanLaunchAgentWithoutAutomationMode() async throws {
        let socketPath = temporarySocketPath()
        let terminalRouter = TestTerminalCommandRouter()
        await MainActor.run {
            terminalRouter.defaultPromptState = .idleAtPrompt
        }
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath, terminalCommandRouter: terminalRouter)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "app_control.run_action",
                payload: [
                    "id": .string("agent.launch"),
                    "args": .object([
                        "profileID": .string(AgentKind.codex.rawValue),
                    ]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let sessionID = try #require(response.result?.string("sessionID"))
        #expect(response.result?.string("panelID") == server.panelID.uuidString)
        #expect(response.result?.int("stateVersion") == 1)
        let activeAgent = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.agent
        }
        #expect(activeAgent == .codex)
    }

    @Test
    func automationPerformActionRemainsGatedWithoutAutomationMode() async throws {
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
                command: "automation.perform_action",
                payload: [
                    "action": .string("window.sidebar.toggle"),
                    "args": .object([:]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok == false)
        #expect(response.error?.message == "automation.perform_action requires automation mode")
    }

    @Test
    func automationPerformActionCanToggleSidebar() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                automationConfig: AutomationConfig(
                    runID: "toggle-sidebar",
                    fixtureName: nil,
                    artifactsDirectory: nil,
                    socketPath: socketPath,
                    disableAnimations: true,
                    fixedLocaleIdentifier: nil,
                    fixedTimeZoneIdentifier: nil
                )
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let initialSidebarVisible = await MainActor.run {
            server.store.state.windows.first?.sidebarVisible
        }
        #expect(initialSidebarVisible == true)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "automation.perform_action",
                payload: [
                    "action": .string("window.sidebar.toggle"),
                    "args": .object([:]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let toggledSidebarVisible = await MainActor.run {
            server.store.state.windows.first?.sidebarVisible
        }
        #expect(toggledSidebarVisible == false)
    }

}
