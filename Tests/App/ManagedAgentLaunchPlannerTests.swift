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
}

@MainActor
private func makePlannerFixture() throws -> (
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
        cliExecutablePathProvider: { "/bin/sh" },
        socketPathProvider: { "/tmp/toastty-tests.sock" },
        readVisibleText: { _ in nil },
        promptState: { _ in .unavailable }
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
