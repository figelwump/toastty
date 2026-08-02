import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct CodexRootProgressCharacterizationTests {
    @Test
    func hookAuthorityProjectsPromptAndToolProgressWithoutActionableEffects() async {
        let scenario = CodexLegacyScenarioDriver(
            trackingSource: .hooks,
            applicationIsActive: false,
            sessionPanelPlacement: .background
        )
        defer { scenario.reset() }
        scenario.setStatus(SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"))

        #expect(scenario.sendHookEvent(
            name: "UserPromptSubmit",
            threadID: "thread-root",
            turnID: "turn-root",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Review the architecture")
        ))
        #expect(scenario.snapshot().recordStatus == SessionStatus(
            kind: .working,
            summary: "Working",
            detail: "Review the architecture"
        ))

        #expect(scenario.sendHookEvent(
            name: "PreToolUse",
            threadID: "thread-root",
            turnID: "turn-root",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running focused tests")
        ))

        let snapshot = scenario.snapshot()
        #expect(snapshot.recordStatus == SessionStatus(
            kind: .working,
            summary: "Working",
            detail: "Running focused tests"
        ))
        #expect(snapshot.workspaceStatus == snapshot.recordStatus)
        #expect(snapshot.panelIsUnread == false)
        #expect(await scenario.capturedEffects().isEmpty)
    }

    @Test
    func fallbackAuthorityRejectsHookProgressWithoutMutatingProjection() async {
        let scenario = CodexLegacyScenarioDriver(
            trackingSource: .sessionLogFallback(reason: "characterization"),
            applicationIsActive: false,
            sessionPanelPlacement: .background
        )
        defer { scenario.reset() }
        let idle = SessionStatus(kind: .idle, summary: "Waiting", detail: "Preserve fallback idle")
        scenario.setStatus(idle)

        #expect(scenario.sendHookEvent(
            name: "UserPromptSubmit",
            threadID: "thread-root",
            turnID: "turn-root",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Hook prompt")
        ) == false)
        #expect(scenario.sendHookEvent(
            name: "PreToolUse",
            threadID: "thread-root",
            turnID: "turn-root",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Hook tool")
        ) == false)

        let snapshot = scenario.snapshot()
        #expect(snapshot.recordStatus == idle)
        #expect(snapshot.workspaceStatus == idle)
        #expect(snapshot.panelIsUnread == false)
        #expect(await scenario.capturedEffects().isEmpty)
    }

    @Test
    func fallbackLaunchLogStartsWorkAndOnlyAbortsActiveOrApprovalProgress() async throws {
        var historyReadCount = 0
        let fixture = try CodexRootProgressPlannerFixture(
            source: .sessionLogFallback(reason: "characterization"),
            readVisibleText: {
                historyReadCount += 1
                return nil
            }
        )
        defer { fixture.cleanUp() }

        try fixture.appendLaunchLog(
            #"{"ts":"2026-07-30T10:00:00.000Z","dir":"from_tui","kind":"op","payload":{"type":"user_turn","items":[{"type":"text","text":"Inspect session progress"}]}}"#
        )
        #expect(await fixture.waitForStatus(
            SessionStatus(kind: .working, summary: "Working", detail: "Inspect session progress")
        ))
        #expect(fixture.panelIsUnread == false)
        #expect(await fixture.notificationCount == 0)

        try fixture.appendLaunchLog(
            #"{"ts":"2026-07-30T10:00:01.000Z","dir":"from_tui","kind":"op","payload":{"type":"interrupt"}}"#
        )
        #expect(await fixture.waitForStatus(
            SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        ))

        fixture.setStatus(SessionStatus(
            kind: .needsApproval,
            summary: "Needs approval",
            detail: "Approve focused tests"
        ))
        try fixture.appendLaunchLog(
            #"{"ts":"2026-07-30T10:00:02.000Z","dir":"from_tui","kind":"op","payload":{"type":"interrupt"}}"#
        )
        #expect(await fixture.waitForStatus(
            SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        ))

        let protectedStatuses = [
            SessionStatus(kind: .idle, summary: "Waiting", detail: "Preserve idle"),
            SessionStatus(kind: .ready, summary: "Ready", detail: "Preserve ready"),
            SessionStatus(kind: .error, summary: "Error", detail: "Preserve error"),
        ]
        for (index, protectedStatus) in protectedStatuses.enumerated() {
            fixture.setStatus(protectedStatus)
            try fixture.appendLaunchLog(
                #"{"ts":"2026-07-30T10:00:1\#(index).000Z","dir":"from_tui","kind":"op","payload":{"type":"interrupt"}}"#
            )
            try fixture.appendLaunchLog(
                #"{"ts":"2026-07-30T10:00:2\#(index).000Z","dir":"to_tui","kind":"insert_history_cell","lines":\#(index + 1)}"#
            )
            #expect(await fixture.waitUntil { historyReadCount == index + 1 })
            #expect(fixture.status == protectedStatus)
        }
    }

    @Test
    func hookAuthorityRejectsLaunchLogProgress() async throws {
        let fixture = try CodexRootProgressPlannerFixture(source: .hooks)
        defer { fixture.cleanUp() }
        let idle = SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")

        try fixture.appendLaunchLog(
            #"{"ts":"2026-07-30T11:00:00.000Z","dir":"from_tui","kind":"op","payload":{"type":"user_turn","items":[{"type":"text","text":"Ignored fallback prompt"}]}}"#
        )
        try fixture.appendLaunchLog(
            #"{"ts":"2026-07-30T11:00:01.000Z","dir":"from_tui","kind":"op","payload":{"type":"interrupt"}}"#
        )
        try await Task.sleep(for: .milliseconds(500))

        #expect(fixture.status == idle)
        #expect(fixture.workspaceStatus == idle)
    }

    @Test
    func fallbackHistoryRefreshesWorkingDetailWithoutResurrectingTerminalStates() async throws {
        var visibleTextReadCount = 0
        let fixture = try CodexRootProgressPlannerFixture(
            source: .sessionLogFallback(reason: "characterization"),
            readVisibleText: {
                visibleTextReadCount += 1
                return "• Running focused root progress tests"
            },
            promptState: { .busy }
        )
        defer { fixture.cleanUp() }
        fixture.setStatus(SessionStatus(
            kind: .working,
            summary: "Working",
            detail: "Responding to your prompt"
        ))

        try fixture.appendLaunchLog(
            #"{"ts":"2026-07-30T12:00:00.000Z","dir":"to_tui","kind":"insert_history_cell","lines":1}"#
        )
        #expect(await fixture.waitForStatus(SessionStatus(
            kind: .working,
            summary: "Working",
            detail: "Running focused root progress tests"
        )))
        #expect(visibleTextReadCount == 1)

        let protectedStatuses = [
            SessionStatus(kind: .idle, summary: "Waiting", detail: "Preserve idle"),
            SessionStatus(kind: .ready, summary: "Ready", detail: "Preserve ready"),
            SessionStatus(kind: .error, summary: "Error", detail: "Preserve error"),
        ]
        for (index, protectedStatus) in protectedStatuses.enumerated() {
            fixture.setStatus(protectedStatus)
            try fixture.appendLaunchLog(
                #"{"ts":"2026-07-30T12:00:1\#(index).000Z","dir":"to_tui","kind":"insert_history_cell","lines":\#(index + 2)}"#
            )
            let expectedReadCount = index + 2
            #expect(await fixture.waitUntil { visibleTextReadCount == expectedReadCount })
            #expect(fixture.status == protectedStatus)
        }
    }

    @Test
    func hookAuthorityDoesNotSampleVisibleTextForHistoryUpdates() async throws {
        var visibleTextReadCount = 0
        let fixture = try CodexRootProgressPlannerFixture(
            source: .hooks,
            readVisibleText: {
                visibleTextReadCount += 1
                return "• Running ignored fallback work"
            },
            promptState: { .busy }
        )
        defer { fixture.cleanUp() }
        let working = SessionStatus(
            kind: .working,
            summary: "Working",
            detail: "Hook-owned progress"
        )
        fixture.setStatus(working)

        try fixture.appendLaunchLog(
            #"{"ts":"2026-07-30T13:00:00.000Z","dir":"to_tui","kind":"insert_history_cell","lines":1}"#
        )
        try await Task.sleep(for: .milliseconds(500))

        #expect(visibleTextReadCount == 0)
        #expect(fixture.status == working)
        #expect(fixture.workspaceStatus == working)
    }
}

@MainActor
private final class CodexRootProgressPlannerFixture {
    private let store: AppStore
    private let sessionStore: SessionRuntimeStore
    private let planner: ManagedAgentLaunchPlanner
    private let plan: ManagedAgentLaunchPlan
    private let notificationRecorder: CodexRootProgressNotificationRecorder
    private let logURL: URL
    private let artifactsDirectoryURL: URL
    private var eventIndex = 0

    init(
        source: CodexStatusTrackingSource,
        readVisibleText: @escaping @MainActor () -> String? = { nil },
        promptState: @escaping @MainActor () -> TerminalPromptState = { .unavailable }
    ) throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let notificationRecorder = CodexRootProgressNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { _, _, _, _, _ in
                await notificationRecorder.record()
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: store)
        let panelID = try Self.requirePanelID(from: store)
        let planner = ManagedAgentLaunchPlanner(
            store: store,
            sessionRuntimeStore: sessionStore,
            fileManager: .default,
            repositoryRootResolver: { _ in
                RepositoryRootResolution(repoRoot: "/tmp/repo", duration: 0, timedOut: false)
            },
            nowProvider: Date.init,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-root-progress-tests.sock" },
            codexStatusTrackingSourceProvider: { source },
            readVisibleText: { _ in readVisibleText() },
            promptState: { _ in promptState() },
            nativeSessionObserverRegistry: CodexRootProgressNativeSessionObserverStub()
        )
        let plan = try planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        guard let logPath = plan.environment["CODEX_TUI_SESSION_LOG_PATH"] else {
            throw CodexRootProgressFixtureError.missingSessionLogPath
        }

        self.store = store
        self.sessionStore = sessionStore
        self.planner = planner
        self.plan = plan
        self.notificationRecorder = notificationRecorder
        logURL = URL(fileURLWithPath: logPath)
        artifactsDirectoryURL = logURL.deletingLastPathComponent()
    }

    var status: SessionStatus? {
        sessionStore.sessionRegistry.activeSession(sessionID: plan.sessionID)?.status
    }

    var workspaceStatus: SessionStatus? {
        sessionStore.workspaceStatuses(for: plan.workspaceID).first { status in
            status.sessionID == plan.sessionID
        }?.status
    }

    var panelIsUnread: Bool {
        store.state.workspacesByID[plan.workspaceID]?.unreadPanelIDs.contains(plan.panelID) == true
    }

    var notificationCount: Int {
        get async {
            await notificationRecorder.count()
        }
    }

    func setStatus(_ status: SessionStatus) {
        eventIndex += 1
        sessionStore.updateStatus(
            sessionID: plan.sessionID,
            status: status,
            at: Date().addingTimeInterval(TimeInterval(eventIndex))
        )
    }

    func appendLaunchLog(_ line: String) throws {
        if FileManager.default.fileExists(atPath: logURL.path) == false {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: Data())
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line.hasSuffix("\n") ? line : line + "\n").utf8))
    }

    func waitForStatus(_ expectedStatus: SessionStatus) async -> Bool {
        await waitUntil { self.status == expectedStatus }
    }

    func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false, Date() < deadline {
            await Task.yield()
        }
        return condition()
    }

    func cleanUp() {
        planner.discardManagedLaunch(sessionID: plan.sessionID)
        sessionStore.unbind()
        try? FileManager.default.removeItem(at: artifactsDirectoryURL)
    }

    private static func requirePanelID(from store: AppStore) throws -> UUID {
        guard let panelID = store.selectedWorkspace?.focusedPanelID else {
            throw CodexRootProgressFixtureError.missingPanel
        }
        return panelID
    }
}

@MainActor
private final class CodexRootProgressNativeSessionObserverStub: ManagedAgentNativeSessionObserving {
    func startObservation(_: ManagedAgentNativeSessionObservationContext) {}
    func cancelObservation(sessionID _: String) {}
}

private enum CodexRootProgressFixtureError: Error {
    case missingPanel
    case missingSessionLogPath
}

private actor CodexRootProgressNotificationRecorder {
    private var recordedCount = 0

    func record() {
        recordedCount += 1
    }

    func count() -> Int {
        recordedCount
    }
}
