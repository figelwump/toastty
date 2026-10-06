import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// Runs the remote start flow against the real agent launcher, with a fake
/// terminal in place of Ghostty.
struct RemoteSessionStarterTests {
    @MainActor
    private final class Fixture {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        let router = TestTerminalCommandRouter()
        let root: URL
        let projectDirectory: String
        let launcher: AgentLaunchService
        let workspaceID: UUID
        let originalPanelID: UUID
        var deviceMayStart = true
        var publishCount = 0
        var currentDate = Date(timeIntervalSince1970: 1_786_200_000)
        private(set) var starter: RemoteSessionStarter!
        let device = RemoteDeviceRecord(
            name: "Phone", scopes: [.read, .send], authKind: .native,
            tailscaleLogin: "owner@example.com", createdAt: Date(timeIntervalSince1970: 0)
        )

        init(readinessTimeout: Duration = .seconds(5)) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("toastty-remote-start-\(UUID().uuidString)", isDirectory: true)
            let project = root.appendingPathComponent("project", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            // realpath, because the launcher normalizes the directory.
            projectDirectory = project.resolvingSymlinksInPath().path
            let claude = bin.appendingPathComponent("claude").path
            FileManager.default.createFile(atPath: claude, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude)

            let cursor = bin.appendingPathComponent("cursor-agent").path
            FileManager.default.createFile(atPath: cursor, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cursor)

            sessionRuntimeStore.bind(store: store)
            router.defaultPromptState = .idleAtPrompt
            let workspace = store.selectedWorkspace!
            workspaceID = workspace.id
            originalPanelID = workspace.focusedPanelID!
            _ = store.send(.updateTerminalPanelMetadata(panelID: originalPanelID, title: nil, cwd: projectDirectory))

            launcher = AgentLaunchService(
                store: store,
                terminalCommandRouter: router,
                sessionRuntimeStore: sessionRuntimeStore,
                agentCatalogProvider: TestAgentCatalogProvider(profiles: [
                    AgentProfile(id: "claude", displayName: "Claude Code", argv: [claude]),
                    AgentProfile(id: "pi", displayName: "Pi", argv: [root.appendingPathComponent("bin/pi").path]),
                    // A wrapper: the launcher cannot mark the end of options.
                    AgentProfile(
                        id: "opencode", displayName: "OpenCode", argv: [claude, "--wrapped"],
                        initialPromptPlacement: .trailing
                    ),
                    AgentProfile(id: "cursor", displayName: "Cursor", argv: [cursor]),
                    // Not shown in the remote session list, so never offered.
                    AgentProfile(id: "grok", displayName: "Grok", argv: [claude]),
                ]),
                cliExecutablePathProvider: { "/bin/sh" },
                socketPathProvider: { "/tmp/toastty-tests.sock" }
            )
            starter = RemoteSessionStarter(
                store: store,
                launcher: launcher,
                now: { [unowned self] in self.currentDate },
                terminalReadinessTimeout: readinessTimeout,
                deviceMayStart: { [unowned self] _ in self.deviceMayStart },
                recentModels: { $0 == .claude ? ["claude-opus-5-5", "claude-fable-5-1"] : [] },
                publishSessionList: { [unowned self] in self.publishCount += 1 }
            )
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var workspace: WorkspaceState { store.state.workspacesByID[workspaceID]! }

        /// The conversation ID stored on a terminal, which is what the
        /// session list publishes for it.
        func conversationID(ofPanel panelID: UUID) -> RemoteConversationID? {
            guard case .terminal(let terminal)? = workspace.panelState(for: panelID) else { return nil }
            return terminal.remoteConversationID
        }

        var newPanelIDs: [UUID] {
            workspace.orderedTabs.dropFirst().compactMap { $0.panels.keys.first }
        }

        func request(
            id: String = "request-1",
            profileID: String = "claude",
            model: String? = "claude-opus-5-5",
            effort: String? = "high",
            text: String = "Fix the flaky test"
        ) -> RemoteSessionStartRequest {
            RemoteSessionStartRequest(
                clientRequestID: id, workspaceID: workspaceID, profileID: profileID,
                model: model, reasoningEffort: effort, text: text
            )
        }

        func start(_ request: RemoteSessionStartRequest) async -> RemoteSessionStartResult {
            await starter.start(request, device: device)
        }
    }

    @MainActor
    @Test func startOpensAnUnselectedTabAndLaunchesTheAgentThereWithoutTakingFocus() async throws {
        let fixture = try Fixture()
        let before = fixture.workspace

        let result = await fixture.start(fixture.request())

        let workspace = fixture.workspace
        #expect(workspace.tabIDs.count == before.tabIDs.count + 1)
        #expect(workspace.resolvedSelectedTabID == before.resolvedSelectedTabID)
        #expect(workspace.focusedPanelID == fixture.originalPanelID)
        let newTab = try #require(workspace.orderedTabs.last)
        let panelID = try #require(newTab.panels.keys.first)
        guard case .terminal(let terminal) = newTab.panels[panelID] else {
            Issue.record("expected a terminal in the new tab")
            return
        }
        #expect(terminal.profileBinding == nil)

        #expect(result == .started(conversationID: try #require(fixture.conversationID(ofPanel: panelID))))
        #expect(fixture.publishCount == 1)
        // Nothing was typed into the terminal the person was using.
        #expect(fixture.router.sentTextByPanelID[fixture.originalPanelID] == nil)
        let command = try #require(fixture.router.sentTextByPanelID[panelID])
        #expect(command.contains("--model claude-opus-5-5"))
        #expect(command.contains("--effort high"))
        #expect(command.contains("'Fix the flaky test'"))
        #expect(command.contains("cd \(fixture.projectDirectory)"))
        #expect(fixture.router.focusPolicyByPanelID[panelID] == .preserveFirstResponder)
        let session = try #require(fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID))
        #expect(session.agent == .claude)
    }

    @MainActor
    @Test func aMessageThatStartsWithADashIsPassedAsTextOrRefused() async throws {
        let fixture = try Fixture()

        let result = await fixture.start(fixture.request(model: nil, effort: nil, text: "--help me refactor"))
        guard case .started = result else {
            Issue.record("expected the start to succeed, got \(result)")
            return
        }
        let panelID = try #require(fixture.newPanelIDs.first)
        #expect(try #require(fixture.router.sentTextByPanelID[panelID]).contains(" -- '--help me refactor'"))

        // A wrapper command has no known end-of-options marker.
        let tabCount = fixture.workspace.tabIDs.count
        let refused = await fixture.start(fixture.request(
            id: "request-2", profileID: "opencode", model: nil, effort: nil, text: "--help me refactor"
        ))
        #expect(refused == .rejected(reason: .invalidRequest))
        #expect(fixture.workspace.tabIDs.count == tabCount)
    }

    @MainActor
    @Test func repeatingARequestReturnsTheFirstConversationAndStartsNothing() async throws {
        let fixture = try Fixture()
        let first = await fixture.start(fixture.request())
        let tabCount = fixture.workspace.tabIDs.count

        let repeated = await fixture.start(fixture.request())
        #expect(repeated == first)
        #expect(fixture.workspace.tabIDs.count == tabCount)
        #expect(fixture.router.sentTextByPanelID.count == 1)

        // A different request ID is a different start.
        let second = await fixture.start(fixture.request(id: "request-2"))
        #expect(second != first)
        #expect(fixture.workspace.tabIDs.count == tabCount + 1)
    }

    @MainActor
    @Test func aRepeatDuringTheLaunchJoinsItAndAnotherRequestFromTheDeviceIsBusy() async throws {
        let fixture = try Fixture()
        // The new shell has not printed its prompt yet, so the launch waits.
        fixture.router.defaultPromptState = .busy
        async let first = fixture.start(fixture.request())
        await SessionRuntimeStoreTestSupport.waitUntil { fixture.workspace.tabIDs.count == 2 }

        let other = await fixture.start(fixture.request(id: "request-2"))
        #expect(other == .rejected(reason: .busy))
        async let repeated = fixture.start(fixture.request())

        fixture.router.defaultPromptState = .idleAtPrompt
        let results = await [first, repeated]
        guard case .started = results[0] else {
            Issue.record("expected the start to succeed once the prompt appeared, got \(results[0])")
            return
        }
        #expect(results[0] == results[1])
        #expect(fixture.workspace.tabIDs.count == 2)
        #expect(fixture.router.sentTextByPanelID.count == 1)
    }

    @MainActor
    @Test func aTerminalThatNeverBecomesReadyFailsTheStartAndRemovesItsTab() async throws {
        let fixture = try Fixture(readinessTimeout: .milliseconds(300))
        fixture.router.defaultPromptState = .busy
        let before = fixture.workspace.tabIDs

        let result = await fixture.start(fixture.request())

        #expect(result == .rejected(reason: .launchFailed))
        #expect(fixture.workspace.tabIDs == before)
        #expect(fixture.publishCount == 0)
        #expect(fixture.router.sentTextByPanelID.isEmpty)

        // Nothing was launched, so the same request may be tried again.
        fixture.router.defaultPromptState = .idleAtPrompt
        guard case .started = await fixture.start(fixture.request()) else {
            Issue.record("expected the retry to start")
            return
        }
    }

    @MainActor
    @Test func permissionRemovedDuringTheLaunchStopsTheCommandFromBeingSent() async throws {
        let fixture = try Fixture()
        fixture.router.defaultPromptState = .busy
        let before = fixture.workspace.tabIDs
        async let pending = fixture.start(fixture.request())
        await SessionRuntimeStoreTestSupport.waitUntil { fixture.workspace.tabIDs.count == 2 }

        fixture.deviceMayStart = false
        fixture.router.defaultPromptState = .idleAtPrompt

        #expect(await pending == .rejected(reason: .permissionDenied))
        #expect(fixture.router.sentTextByPanelID.isEmpty)
        #expect(fixture.workspace.tabIDs == before)
        #expect(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.values.contains { $0.isActive } == false)
    }

    @MainActor
    @Test func aTabThePersonOpenedDuringTheLaunchIsNotRemovedWhenTheStartFails() async throws {
        let fixture = try Fixture(readinessTimeout: .milliseconds(600))
        fixture.router.defaultPromptState = .busy
        async let pending = fixture.start(fixture.request())
        await SessionRuntimeStoreTestSupport.waitUntil { fixture.workspace.tabIDs.count == 2 }
        let originalTabID = try #require(fixture.workspace.tabIDs.first)
        let newTabID = try #require(fixture.workspace.tabIDs.last)

        // The person looks at the new tab, then goes back.
        _ = fixture.store.send(.selectWorkspaceTab(workspaceID: fixture.workspaceID, tabID: newTabID))
        try await Task.sleep(for: .milliseconds(350))
        _ = fixture.store.send(.selectWorkspaceTab(workspaceID: fixture.workspaceID, tabID: originalTabID))

        #expect(await pending == .rejected(reason: .launchFailed))
        #expect(fixture.workspace.tabIDs.contains(newTabID))
    }

    @MainActor
    @Test func aCommandTheTerminalDidNotConfirmIsNotSentAgainAndItsTabStays() async throws {
        let fixture = try Fixture()
        fixture.router.sendSucceeds = false
        fixture.router.sendFailure = .uncertain

        let result = await fixture.start(fixture.request())

        #expect(result == .rejected(reason: .launchFailed))
        // One delivery attempt, and the tab remains for the person to see.
        #expect(fixture.router.sendAttemptCount == 1)
        #expect(fixture.workspace.tabIDs.count == 2)
    }

    @MainActor
    @Test func aTerminalThatRefusesInputBeforeTakingAnyIsTriedAgain() async throws {
        let fixture = try Fixture()
        // The surface exists and shows a prompt but is not accepting input yet.
        fixture.router.failingSendCount = 2

        let result = await fixture.start(fixture.request())

        guard case .started(let conversationID) = result else {
            Issue.record("expected the start to succeed on a later attempt, got \(result)")
            return
        }
        #expect(fixture.router.sendAttemptCount == 3)
        #expect(fixture.workspace.tabIDs.count == 2)
        let panelID = try #require(fixture.newPanelIDs.first)
        #expect(fixture.conversationID(ofPanel: panelID) == conversationID)
    }

    @MainActor
    @Test func rememberedStartsExpireButAreNeverDroppedEarly() async throws {
        let fixture = try Fixture()
        let first = await fixture.start(fixture.request())

        // Just inside the window, the repeat is still the first session.
        fixture.currentDate += RemoteSessionStartPolicy.duplicateRequestWindow - 1
        #expect(await fixture.start(fixture.request()) == first)
        #expect(fixture.workspace.tabIDs.count == 2)

        // After the window, the same ID is a new start.
        fixture.currentDate += 2
        let later = await fixture.start(fixture.request())
        #expect(later != first)
        #expect(fixture.workspace.tabIDs.count == 3)
    }

    @MainActor
    @Test func startsAreRefusedBeforeAnyTabOpensWhenTheRequestCannotBeServed() async throws {
        let fixture = try Fixture()
        let before = fixture.workspace.tabIDs
        var unknownWorkspace = fixture.request()
        unknownWorkspace.workspaceID = UUID()

        #expect(await fixture.start(unknownWorkspace) == .rejected(reason: .workspaceNotFound))
        #expect(await fixture.start(fixture.request(profileID: "pi")) == .rejected(reason: .agentUnavailable))
        #expect(await fixture.start(fixture.request(profileID: "grok")) == .rejected(reason: .agentUnavailable))
        #expect(await fixture.start(fixture.request(profileID: "missing")) == .rejected(reason: .agentUnavailable))
        #expect(await fixture.start(fixture.request(effort: "turbo")) == .rejected(reason: .invalidRequest))

        _ = fixture.store.send(.updateTerminalPanelMetadata(
            panelID: fixture.originalPanelID, title: nil, cwd: fixture.root.appendingPathComponent("gone").path
        ))
        #expect(await fixture.start(fixture.request()) == .rejected(reason: .workspaceUnavailable))
        #expect(fixture.workspace.tabIDs == before)
        #expect(fixture.router.sentTextByPanelID.isEmpty)
    }

    @MainActor
    @Test func installedPiIsAvailableAndStartsWithTheFirstMessage() async throws {
        for text in ["Review this change", "--help me refactor"] {
            let fixture = try Fixture()
            let executable = fixture.root.appendingPathComponent("bin/pi").path
            FileManager.default.createFile(atPath: executable, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
            let options = fixture.starter.options(
                for: RemoteSessionStartOptionsRequest(workspaceID: fixture.workspaceID), device: fixture.device
            )
            #expect(try #require(options.agents.first { $0.profileID == "pi" }).availability == .available)
            let before = fixture.workspace
            let result = await fixture.start(fixture.request(profileID: "pi", model: nil, effort: nil, text: text))
            guard case .started(let conversationID) = result else {
                Issue.record("expected Pi to start, got \(result)")
                continue
            }
            let panelID = try #require(fixture.newPanelIDs.first)
            #expect(fixture.conversationID(ofPanel: panelID) == conversationID)
            #expect(fixture.workspace.resolvedSelectedTabID == before.resolvedSelectedTabID)
            #expect(fixture.workspace.focusedPanelID == fixture.originalPanelID)
            #expect(fixture.router.sentTextByPanelID[fixture.originalPanelID] == nil)
            let boundary = text.hasPrefix("-") ? " --" : ""
            let command = try #require(fixture.router.sentTextByPanelID[panelID])
            #expect(command.contains(executable))
            #expect(command.contains("\(boundary) '\(text)'"))
            #expect(fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID)?.agent == .pi)
        }
    }

    @MainActor
    @Test func cursorOffersModelWithoutReasoningAndStartsWithAutoModel() async throws {
        let fixture = try Fixture()
        let options = fixture.starter.options(
            for: RemoteSessionStartOptionsRequest(workspaceID: fixture.workspaceID), device: fixture.device
        )
        let cursor = try #require(options.agents.first { $0.profileID == "cursor" })
        #expect(cursor.availability == .available)
        #expect(cursor.supportsModel)
        #expect(cursor.reasoningEfforts.isEmpty)
        #expect(await fixture.start(fixture.request(profileID: "cursor", model: "auto", effort: "high"))
            == .rejected(reason: .invalidRequest))
        #expect(fixture.newPanelIDs.isEmpty)

        let result = await fixture.start(fixture.request(
            profileID: "cursor", model: "auto", effort: nil, text: "Explain this change"
        ))
        guard case .started(let conversationID) = result else {
            Issue.record("expected Cursor to start, got \(result)")
            return
        }
        let panelID = try #require(fixture.newPanelIDs.first)
        #expect(fixture.conversationID(ofPanel: panelID) == conversationID)
        let command = try #require(fixture.router.sentTextByPanelID[panelID])
        #expect(command.contains("cursor-agent"))
        #expect(command.contains("--model auto"))
        #expect(command.contains("'Explain this change'"))
        #expect(command.contains("--effort") == false)
        #expect(fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID)?.agent == .cursor)
        #expect(fixture.router.sentTextByPanelID[fixture.originalPanelID] == nil)
    }

    @MainActor
    @Test func optionsListOnlyAgentsTheSessionListCanShowWithTheirChoices() throws {
        let fixture = try Fixture()
        let options = fixture.starter.options(
            for: RemoteSessionStartOptionsRequest(workspaceID: fixture.workspaceID),
            device: fixture.device
        )

        #expect(options.permission == .allowed)
        #expect(options.workspace == .available)
        #expect(options.launchDirectory == fixture.projectDirectory)
        #expect(options.agents.map(\.profileID) == ["claude", "pi", "opencode", "cursor"])
        let claude = try #require(options.agents.first)
        #expect(claude.availability == .available)
        #expect(claude.supportsModel)
        #expect(claude.recentModels == ["claude-opus-5-5", "claude-fable-5-1"])
        #expect(claude.reasoningEfforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(options.agents[1].availability == .notInstalled)
        // OpenCode takes a model but has no effort setting.
        #expect(options.agents[2].supportsModel)
        #expect(options.agents[2].reasoningEfforts.isEmpty)

        var disabled = fixture.device
        disabled.sessionStartDisabled = true
        #expect(fixture.starter.options(
            for: RemoteSessionStartOptionsRequest(workspaceID: fixture.workspaceID), device: disabled
        ).permission == .startDisabled)
        #expect(fixture.starter.options(
            for: RemoteSessionStartOptionsRequest(workspaceID: UUID()), device: fixture.device
        ).workspace == .notFound)
    }
}
