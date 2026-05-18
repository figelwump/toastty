import CoreState
import XCTest
@testable import ToasttyApp

@MainActor
final class ManagedAgentLaunchPlannerTests: XCTestCase {
    func testClaudeArtifactsRemainAfterSessionStops() async throws {
        let fixture = try makePlannerFixture()
        let claudePlan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .claude,
                panelID: fixture.panelID,
                argv: ["claude"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try claudeArtifactsDirectory(from: claudePlan)
        let codexPlan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let codexArtifactsDirectoryURL = try codexArtifactsDirectory(from: codexPlan)
        defer {
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
            try? fixture.fileManager.removeItem(at: codexArtifactsDirectoryURL)
        }

        XCTAssertTrue(fixture.fileManager.fileExists(atPath: artifactsDirectoryURL.path))
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: codexArtifactsDirectoryURL.path))

        fixture.sessionRuntimeStore.stopSession(sessionID: claudePlan.sessionID, at: Date())
        fixture.sessionRuntimeStore.stopSession(sessionID: codexPlan.sessionID, at: Date())
        await waitUntil {
            fixture.fileManager.fileExists(atPath: codexArtifactsDirectoryURL.path) == false
        }

        XCTAssertTrue(
            fixture.fileManager.fileExists(atPath: artifactsDirectoryURL.path),
            "Claude hook artifacts should remain available across later cleanup passes"
        )
    }

    func testCodexArtifactsDeleteImmediatelyAfterSessionStops() async throws {
        let fixture = try makePlannerFixture()
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)

        XCTAssertTrue(fixture.fileManager.fileExists(atPath: artifactsDirectoryURL.path))

        fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
        await waitUntil {
            fixture.fileManager.fileExists(atPath: artifactsDirectoryURL.path) == false
        }

        XCTAssertFalse(
            fixture.fileManager.fileExists(atPath: artifactsDirectoryURL.path),
            "Codex launch artifacts should continue deleting on session stop"
        )
    }

    func testCodexLaunchPlanDisablesEnhancedKeyboardReporting() throws {
        let fixture = try makePlannerFixture()
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }

        XCTAssertEqual(plan.environment["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"], "1")
        XCTAssertEqual(plan.environment["CODEX_TUI_RECORD_SESSION"], "1")
        XCTAssertEqual(
            plan.environment["TOASTTY_PANEL_ID"],
            fixture.panelID.uuidString
        )
    }

    func testCodexSessionConfiguredEventPersistsResumeRecordAndCancelsLaunchScanner() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-codex-session-configured-\(UUID().uuidString)", isDirectory: true)
        let cwdURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let codexSessionsURL = rootURL.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSessionsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let observer = StubManagedAgentNativeSessionObserver()
        let resolver = CodexManagedSessionResolver(codexSessionsDirectory: codexSessionsURL)
        let fixture = try makePlannerFixture(
            nativeSessionObserverRegistry: observer,
            codexResumeResolver: resolver
        )
        let threadID = "019e316e-9f7f-7a33-aad9-33fe27b0f2cd"
        let rolloutURL = codexSessionsURL.appendingPathComponent("rollout-\(threadID).jsonl", isDirectory: false)
        try Data(
            #"{"type":"session_meta","payload":{"id":"\#(threadID)","cwd":"\#(cwdURL.path)"}}"#.utf8
        ).write(to: rolloutURL)

        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: cwdURL.path
            )
        )
        let artifactsDirectoryURL = try codexArtifactsDirectory(from: plan)
        defer {
            fixture.sessionRuntimeStore.stopSession(sessionID: plan.sessionID, at: Date())
            try? fixture.fileManager.removeItem(at: artifactsDirectoryURL)
        }
        let logURL = try codexSessionLogURL(from: plan)

        try appendCodexSessionLogLine(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"\(threadID)","thread_id":"\(threadID)","cwd":"\(cwdURL.path)","rollout_path":"\(rolloutURL.path)"}}}
            """,
            to: logURL
        )

        await waitUntil {
            (try? terminalState(panelID: fixture.panelID, state: fixture.store.state).resumeRecord?.nativeSessionID) == threadID
        }

        let resumeRecord = try XCTUnwrap(terminalState(panelID: fixture.panelID, state: fixture.store.state).resumeRecord)
        XCTAssertEqual(resumeRecord.agent, .codex)
        XCTAssertEqual(resumeRecord.nativeSessionID, threadID)
        XCTAssertEqual(resumeRecord.sessionFilePath, rolloutURL.path)
        XCTAssertEqual(resumeRecord.cwd, cwdURL.path)
        XCTAssertTrue(observer.cancelledSessionIDs.contains(plan.sessionID))
    }

    func testCodexLaunchPlanDisablesEnhancedKeyboardReportingWhenInstrumentationFails() throws {
        let fixture = try makePlannerFixture(fileManager: ThrowingCreateDirectoryFileManager())
        let plan = try fixture.planner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: fixture.panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )

        XCTAssertEqual(plan.argv, ["codex"])
        XCTAssertEqual(plan.environment["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"], "1")
        XCTAssertNil(plan.environment["CODEX_TUI_RECORD_SESSION"])
        XCTAssertEqual(
            plan.environment["TOASTTY_PANEL_ID"],
            fixture.panelID.uuidString
        )
    }
}

@MainActor
private func makePlannerFixture(
    fileManager: FileManager = .default,
    nativeSessionObserverRegistry: (any ManagedAgentNativeSessionObserving)? = nil,
    codexResumeResolver: (any CodexManagedSessionResolving)? = nil
) throws -> (
    store: AppStore,
    planner: ManagedAgentLaunchPlanner,
    sessionRuntimeStore: SessionRuntimeStore,
    panelID: UUID,
    fileManager: FileManager
) {
    let store = AppStore(persistTerminalFontPreference: false)
    let sessionRuntimeStore = SessionRuntimeStore()
    sessionRuntimeStore.bind(store: store)
    let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

    let planner = ManagedAgentLaunchPlanner(
        store: store,
        sessionRuntimeStore: sessionRuntimeStore,
        fileManager: fileManager,
        cliExecutablePathProvider: { "/bin/sh" },
        socketPathProvider: { "/tmp/toastty-tests.sock" },
        readVisibleText: { _ in nil },
        promptState: { _ in .unavailable },
        nativeSessionObserverRegistry: nativeSessionObserverRegistry,
        codexResumeResolver: codexResumeResolver
    )

    return (store, planner, sessionRuntimeStore, panelID, .default)
}

private func claudeArtifactsDirectory(from plan: ManagedAgentLaunchPlan) throws -> URL {
    let settingsIndex = try XCTUnwrap(plan.argv.firstIndex(of: "--settings"))
    let settingsPath = try XCTUnwrap(plan.argv[safe: settingsIndex + 1])
    return URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
}

private func codexArtifactsDirectory(from plan: ManagedAgentLaunchPlan) throws -> URL {
    let configIndex = try XCTUnwrap(plan.argv.firstIndex(of: "-c"))
    let configValue = try XCTUnwrap(plan.argv[safe: configIndex + 1])
    let prefix = "notify=[\"/bin/sh\",\""
    let suffix = "\"]"

    XCTAssertTrue(configValue.hasPrefix(prefix))
    XCTAssertTrue(configValue.hasSuffix(suffix))

    let startIndex = configValue.index(configValue.startIndex, offsetBy: prefix.count)
    let endIndex = configValue.index(configValue.endIndex, offsetBy: -suffix.count)
    let notifyScriptPath = String(configValue[startIndex..<endIndex])
    return URL(fileURLWithPath: notifyScriptPath).deletingLastPathComponent()
}

private func codexSessionLogURL(from plan: ManagedAgentLaunchPlan) throws -> URL {
    let path = try XCTUnwrap(plan.environment["CODEX_TUI_SESSION_LOG_PATH"])
    return URL(fileURLWithPath: path)
}

private func appendCodexSessionLogLine(_ line: String, to url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) == false {
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line.hasSuffix("\n") ? line : line + "\n").utf8))
}

@MainActor
private func terminalState(panelID: UUID, state: AppState) throws -> TerminalPanelState {
    let workspace = try XCTUnwrap(state.workspacesByID.values.first { $0.panelState(for: panelID) != nil })
    guard case .terminal(let terminalState) = workspace.panelState(for: panelID) else {
        XCTFail("expected terminal panel state")
        throw ManagedAgentLaunchPlannerTestError.expectedTerminalPanel
    }
    return terminalState
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
    while condition() == false && Date() < deadline {
        await Task.yield()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

private final class ThrowingCreateDirectoryFileManager: FileManager {
    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private enum ManagedAgentLaunchPlannerTestError: Error {
    case expectedTerminalPanel
}

@MainActor
private final class StubManagedAgentNativeSessionObserver: ManagedAgentNativeSessionObserving {
    private(set) var observations: [ManagedAgentNativeSessionObservationContext] = []
    private(set) var cancelledSessionIDs: [String] = []

    func startObservation(_ observation: ManagedAgentNativeSessionObservationContext) {
        observations.append(observation)
    }

    func cancelObservation(sessionID: String) {
        cancelledSessionIDs.append(sessionID)
    }
}
