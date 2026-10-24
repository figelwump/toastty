import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

struct CoordinatorSessionControllerTests {
    @MainActor
    private final class Launcher: TaskAgentLaunching {
        let store: AppStore
        let runtime: SessionRuntimeStore
        var attempts = 0
        var launches = 0
        var suspend = false
        var gate: CheckedContinuation<Void, Never>?
        var failure: AgentLaunchError?
        var exitsBeforeReturning = false
        var models: [String?] = []
        var profiles = [AgentLaunchProfileSummary(
            profileID: "claude", displayName: "Claude", agent: .claude,
            isInstalled: true, acceptsInitialPrompt: true, acceptsLeadingDashPrompt: true,
            supportsModel: true, supportsReasoningEffort: true
        )]

        init(store: AppStore, runtime: SessionRuntimeStore) { self.store = store; self.runtime = runtime }
        func launchProfileSummaries() -> [AgentLaunchProfileSummary] { profiles }
        func launchTask(
            profileID: String, workspaceID: UUID, panelID: UUID, cwd: String,
            model: String?, reasoningEffort: String?, initialPrompt: String,
            parentSessionID: String?, forkFromSessionID: String?, scopedWorkspaceIDs: Set<UUID>?,
            beforeDispatch: @escaping @MainActor () throws -> Void
        ) async throws -> AgentLaunchResult {
            attempts += 1
            if suspend { await withCheckedContinuation { gate = $0 } }
            let sessionID = UUID().uuidString
            let windowID = try #require(store.state.windows.first { $0.workspaceIDs.contains(workspaceID) }?.id)
            // Match ManagedAgentLaunchPlanner: register before dispatch, and
            // discard that runtime if the launch fails or is cancelled.
            register(sessionID: sessionID, workspaceID: workspaceID, panelID: panelID, windowID: windowID)
            do {
                try beforeDispatch()
                if let failure { throw failure }
            } catch {
                runtime.stopSession(sessionID: sessionID, at: Date())
                throw error
            }
            #expect(initialPrompt.contains("toastty-coordinator"))
            #expect(parentSessionID == nil && forkFromSessionID == nil && scopedWorkspaceIDs == nil)
            launches += 1
            models.append(model)
            if exitsBeforeReturning { runtime.stopSession(sessionID: sessionID, at: Date()) }
            return AgentLaunchResult(agent: .claude, displayName: "Claude", sessionID: sessionID,
                                     windowID: windowID, workspaceID: workspaceID, panelID: panelID,
                                     cwd: cwd, repoRoot: nil, commandLine: "fixture")
        }

        func register(sessionID: String, workspaceID: UUID, panelID: UUID, windowID: UUID, agent: AgentKind = .claude) {
            runtime.startSession(sessionID: sessionID, agent: agent, panelID: panelID,
                                 windowID: windowID, workspaceID: workspaceID,
                                 codexStatusTrackingSource: .externallyReported,
                                 cwd: nil, repoRoot: nil, at: Date())
        }

        func release() { suspend = false; gate?.resume(); gate = nil }
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-coordinator-\(UUID())")
        let store = AppStore(persistTerminalFontPreference: false)
        let runtime = SessionRuntimeStore()
        let launcher: Launcher
        let paths: ToasttyRuntimePaths
        let controller: CoordinatorSessionController

        init() {
            paths = .resolve(environment: [ToasttyRuntimePaths.environmentKey: root.path])
            launcher = Launcher(store: store, runtime: runtime)
            runtime.bind(store: store)
            controller = CoordinatorSessionController(store: store, launcher: launcher, sessionRuntimeStore: runtime,
                runtimePaths: paths, defaultsProvider: { .init(agent: "claude", model: "configured-model", effort: "high") },
                terminalReadinessTimeout: .zero)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test @MainActor
    func startsWithoutChangingWindowWorkspaceTabOrPanelSelection() async throws {
        let f = Fixture()
        let selection = try #require(f.store.state.selectedWorkspaceSelection())
        _ = f.store.send(.setDefaultTerminalProfile(profileID: "custom-startup"))
        await f.controller.start()
        let target = try #require(f.controller.identity)
        let after = try #require(f.store.state.selectedWorkspaceSelection())
        #expect(selection.windowID == after.windowID)
        #expect(selection.workspaceID == after.workspaceID)
        #expect(selection.workspace.resolvedSelectedTabID == after.workspace.resolvedSelectedTabID)
        #expect(selection.workspace.focusedPanelID == after.workspace.focusedPanelID)
        #expect(f.controller.status == .running)
        #expect(f.launcher.models == ["configured-model"])
        let workspace = try #require(f.store.state.workspacesByID[target.workspaceID])
        #expect(workspace.orderedTabs.count == 1)
        guard case .terminal(let terminal)? = workspace.panelState(for: target.panelID) else {
            Issue.record("Missing Coordinator terminal"); return
        }
        #expect(terminal.profileBinding == nil)
    }

    @Test @MainActor
    func concurrentWindowStartsShareOneLaunch() async {
        let f = Fixture()
        f.launcher.suspend = true
        let first = Task { await f.controller.start() }
        for _ in 0..<100 where f.launcher.gate == nil { await Task.yield() }
        #expect(f.launcher.gate != nil)
        let second = Task { await f.controller.start() }
        await Task.yield()
        f.launcher.release()
        await first.value
        await second.value
        await f.controller.start()
        #expect(f.launcher.launches == 1)
        #expect(f.controller.status == .running)
    }

    @Test @MainActor
    func restartReusesIdentityAndWaitsForNativeResume() async throws {
        let f = Fixture()
        await f.controller.start()
        let target = try #require(f.controller.identity)
        _ = f.store.send(.updateTerminalPanelResumeRecord(panelID: target.panelID, resumeRecord: .init(
            agent: .claude, nativeSessionID: UUID().uuidString, sessionFilePath: "/fixture/transcript",
            cwd: f.root.path, capturedAt: Date()
        )))
        let restartedRuntime = SessionRuntimeStore()
        restartedRuntime.bind(store: f.store)
        let restartedLauncher = Launcher(store: f.store, runtime: restartedRuntime)
        let restarted = CoordinatorSessionController(store: f.store, launcher: restartedLauncher,
            sessionRuntimeStore: restartedRuntime, runtimePaths: f.paths)
        #expect(restarted.identity == target)
        #expect(restarted.configuration.model == "configured-model")
        #expect(restarted.status == .waitingForRestore)
        await restarted.start()
        #expect(restartedLauncher.attempts == 0)
        let window = try #require(f.store.state.windows.first { $0.workspaceIDs.contains(target.workspaceID) })
        restartedLauncher.register(sessionID: "restored", workspaceID: target.workspaceID, panelID: target.panelID, windowID: window.id)
        #expect(restarted.status == .running)
        #expect(restarted.managedSessionID == "restored")
        restartedRuntime.stopSession(sessionID: "restored", at: Date())
        #expect(restarted.status == .stopped)
        #expect(restartedLauncher.attempts == 0)
    }

    @Test @MainActor
    func disabledDoesNotLaunchAndPersistsAcrossRestart() async throws {
        let f = Fixture()
        try f.controller.setAutomaticWorkEnabled(false)
        await f.controller.startIfAutomaticWorkEnabled()
        #expect(f.launcher.attempts == 0)
        #expect(f.controller.identity == nil)
        let restarted = CoordinatorSessionController(store: f.store, launcher: f.launcher,
            sessionRuntimeStore: f.runtime, runtimePaths: f.paths)
        #expect(!restarted.automaticWorkEnabled)
        await restarted.startIfAutomaticWorkEnabled()
        #expect(f.launcher.attempts == 0)
        await restarted.start()
        #expect(f.launcher.launches == 1)
        try restarted.setAutomaticWorkEnabled(false)
        #expect(restarted.status == .running)
    }

    @Test @MainActor
    func disablingDuringAutomaticLaunchPreventsDispatch() async throws {
        let f = Fixture()
        f.launcher.suspend = true
        let start = Task { await f.controller.startIfAutomaticWorkEnabled() }
        for _ in 0..<100 where f.launcher.gate == nil { await Task.yield() }
        #expect(f.launcher.gate != nil)
        try f.controller.setAutomaticWorkEnabled(false)
        f.launcher.release()
        await start.value
        #expect(f.launcher.launches == 0)
        #expect(f.controller.status == .stopped)
    }

    @Test @MainActor
    func deadOrClosedBackingSessionDoesNotAutoLaunch() async throws {
        let f = Fixture()
        await f.controller.start()
        let target = try #require(f.controller.identity)
        let sessionID = try #require(f.controller.managedSessionID)
        f.runtime.stopSession(sessionID: sessionID, at: Date())
        #expect(f.controller.status == .stopped)
        #expect(f.launcher.launches == 1)
        _ = f.store.send(.closeWorkspace(workspaceID: target.workspaceID))
        #expect(f.controller.status == .stopped)
        #expect(f.controller.managedSessionID == nil)
        await f.controller.start()
        #expect(f.controller.identity == target)
        #expect(f.launcher.launches == 2)
    }

    @Test @MainActor
    func uncertainDeliveryCannotBeReplayedEvenAfterRestart() async throws {
        let f = Fixture()
        f.launcher.failure = .commandDeliveryUncertain(panelID: UUID())
        await f.controller.start()
        if case .error = f.controller.status {} else { Issue.record("Expected uncertain launch error") }
        f.launcher.failure = nil
        await f.controller.start()
        let restarted = CoordinatorSessionController(store: f.store, launcher: f.launcher,
            sessionRuntimeStore: f.runtime, runtimePaths: f.paths)
        await restarted.start()
        #expect(f.launcher.attempts == 1)
    }

    @Test @MainActor
    func corruptStateNeverOverwritesIdentityOrStartsProvider() async throws {
        let f = Fixture()
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let file = f.root.appendingPathComponent("coordinator-session.json")
        let invalid = Data("broken".utf8)
        try invalid.write(to: file)
        let restarted = CoordinatorSessionController(store: f.store, launcher: f.launcher,
            sessionRuntimeStore: f.runtime, runtimePaths: f.paths)
        await restarted.start()
        #expect(f.launcher.attempts == 0)
        #expect(try Data(contentsOf: file) == invalid)
        if case .error = restarted.status {} else { Issue.record("Expected corrupt-state error") }
    }

    @Test @MainActor
    func uncertainRelaunchRemainsBlockedAfterUnrelatedSessionUpdate() async throws {
        let f = Fixture()
        await f.controller.start()
        let oldID = try #require(f.controller.managedSessionID)
        f.runtime.stopSession(sessionID: oldID, at: Date())
        f.launcher.failure = .commandDeliveryUncertain(panelID: try #require(f.controller.identity?.panelID))
        await f.controller.start()
        let selection = try #require(f.store.state.selectedWorkspaceSelection())
        f.launcher.register(sessionID: "unrelated", workspaceID: selection.workspaceID,
            panelID: try #require(selection.workspace.focusedPanelID), windowID: selection.windowID)
        if case .error = f.controller.status {} else { Issue.record("Inspection error was hidden") }
        f.launcher.failure = nil
        await f.controller.start()
        #expect(f.launcher.attempts == 2)
        if case .error = f.controller.status {} else { Issue.record("Blocked Start must retain its explanation") }
    }

    @Test @MainActor
    func launchFailureSurvivesRefreshAndCanBeRetried() async {
        let f = Fixture()
        f.launcher.failure = .panelBusy(runningCommand: nil)
        await f.controller.start()
        f.controller.reconcile()
        if case .error = f.controller.status {} else { Issue.record("Launch error was lost") }
        #expect(f.runtime.sessionRegistry.activeSessionIDByPanelID.isEmpty)
        f.launcher.failure = nil
        await f.controller.start()
        #expect(f.controller.status == .running)
        #expect(f.launcher.attempts == 2)
    }

    @Test @MainActor
    func immediateProviderExitDoesNotRemainRunning() async {
        let f = Fixture()
        f.launcher.exitsBeforeReturning = true
        await f.controller.start()
        #expect(f.controller.status == .stopped)
        #expect(f.runtime.sessionRegistry.activeSessionIDByPanelID.isEmpty)
    }

    @Test @MainActor
    func occupiedBackingPanelRejectsStartBeforeLauncher() async throws {
        let f = Fixture()
        await f.controller.start()
        let target = try #require(f.controller.identity)
        let windowID = try #require(f.store.state.windows.first { $0.workspaceIDs.contains(target.workspaceID) }?.id)
        f.launcher.register(sessionID: "other-provider", workspaceID: target.workspaceID,
            panelID: target.panelID, windowID: windowID, agent: .pi)
        await f.controller.start()
        #expect(f.launcher.attempts == 1)
        if case .unavailable = f.controller.status {} else { Issue.record("Occupied panel must stay unavailable") }
    }

    @Test(arguments: [false, true]) @MainActor
    func failedPanelCreationClosesOnlyWorkspaceCreatedByThisAttempt(existingWorkspace: Bool) async throws {
        let f = Fixture()
        let selection = try #require(f.store.state.selectedWorkspaceSelection())
        let target = CoordinatorSessionIdentity(
            workspaceID: existingWorkspace ? selection.workspaceID : UUID(),
            panelID: try #require(selection.workspace.focusedPanelID))
        // For the existing-workspace branch, put its conflicting panel elsewhere.
        if existingWorkspace {
            _ = f.store.send(.createWorkspace(windowID: selection.windowID, title: "Other", activate: false))
        }
        let actualTarget: CoordinatorSessionIdentity
        if existingWorkspace {
            let other = try #require(f.store.state.windows.first?.workspaceIDs.last)
            actualTarget = .init(workspaceID: other, panelID: target.panelID)
        } else { actualTarget = target }
        let stored = CoordinatorSessionState(configuration: .init(profileID: "claude"), identity: actualTarget)
        try stored.save(to: f.paths.configDirectoryURL.appendingPathComponent("coordinator-session.json"))
        let before = Set(f.store.state.workspacesByID.keys)
        let controller = CoordinatorSessionController(store: f.store, launcher: f.launcher,
            sessionRuntimeStore: f.runtime, runtimePaths: f.paths, terminalReadinessTimeout: .zero)
        await controller.start()
        #expect(Set(f.store.state.workspacesByID.keys) == before)
        #expect(f.launcher.attempts == 0)
        #expect(f.store.state.selectedWorkspaceSelection()?.workspaceID == selection.workspaceID)
    }
}
