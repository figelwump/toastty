#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

final class TerminalActivityInferenceServiceTests: XCTestCase {
    func testRefreshVisibleTextInferencePublishesTransientAgentDisplayTitleOverride() async throws {
        try await MainActor.run {
            let (store, service, workspaceID, panelID, visibleTextStore) = try makeActivityInferenceFixture()
            let originalTitle = try terminalState(panelID: panelID, state: store.state).title

            visibleTextStore.textByPanelID[panelID] = """
            dev@host ~/repo % codex
            OpenAI Codex (v0.1)
            """
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )

            XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).title, originalTitle)
            XCTAssertEqual(service.panelDisplayTitleOverride(for: panelID), "Codex")
            try StateValidator.validate(store.state)
        }
    }

    func testRefreshVisibleTextInferenceClearsDisplayTitleOverrideAtIdlePrompt() async throws {
        try await MainActor.run {
            let (store, service, workspaceID, panelID, visibleTextStore) = try makeActivityInferenceFixture()
            let originalTitle = try terminalState(panelID: panelID, state: store.state).title

            visibleTextStore.textByPanelID[panelID] = """
            dev@host ~/repo % codex
            OpenAI Codex (v0.1)
            """
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )
            XCTAssertEqual(service.panelDisplayTitleOverride(for: panelID), "Codex")

            visibleTextStore.textByPanelID[panelID] = "dev@host ~/repo %"
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )

            XCTAssertNil(service.panelDisplayTitleOverride(for: panelID))
            XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).title, originalTitle)
            try StateValidator.validate(store.state)
        }
    }

    func testRefreshVisibleTextInferenceKeepsDisplayTitleOverrideAcrossTransientBannerMiss() async throws {
        try await MainActor.run {
            let (store, service, workspaceID, panelID, visibleTextStore) = try makeActivityInferenceFixture()
            let originalTitle = try terminalState(panelID: panelID, state: store.state).title

            visibleTextStore.textByPanelID[panelID] = """
            dev@host ~/repo % claude
            Claude Code v1.2.3
            """
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )
            XCTAssertEqual(service.panelDisplayTitleOverride(for: panelID), "Claude Code")

            visibleTextStore.textByPanelID[panelID] = "Applying patch..."
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )

            XCTAssertEqual(service.panelDisplayTitleOverride(for: panelID), "Claude Code")
            XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).title, originalTitle)
            try StateValidator.validate(store.state)
        }
    }

    func testRefreshVisibleTextInferenceDoesNotOverrideCustomTerminalTitle() async throws {
        try await MainActor.run {
            let (store, service, workspaceID, panelID, visibleTextStore) = try makeActivityInferenceFixture()

            XCTAssertTrue(
                store.send(
                    .updateTerminalPanelMetadata(
                        panelID: panelID,
                        title: "Dev Server",
                        cwd: nil
                    )
                )
            )

            visibleTextStore.textByPanelID[panelID] = """
            dev@host ~/repo % codex
            OpenAI Codex (v0.1)
            """
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )

            XCTAssertNil(service.panelDisplayTitleOverride(for: panelID))
            XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).title, "Dev Server")
            try StateValidator.validate(store.state)
        }
    }

    func testRefreshVisibleTextInferencePublishesRunningCommandOverrideForPathTitle() async throws {
        try await MainActor.run {
            let (store, service, workspaceID, panelID, visibleTextStore) = try makeActivityInferenceFixture()
            let repoPath = "/tmp/restored-running-command"

            XCTAssertTrue(
                store.send(
                    .updateTerminalPanelMetadata(
                        panelID: panelID,
                        title: repoPath,
                        cwd: repoPath
                    )
                )
            )

            visibleTextStore.textByPanelID[panelID] = """
            dev@host ~/repo % emptyos dev --port 3913
            Status: running
            PID: 52375
            """
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )

            XCTAssertEqual(service.panelDisplayTitleOverride(for: panelID), "emptyos dev --port 3913")
            XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).title, repoPath)
            try StateValidator.validate(store.state)
        }
    }

    func testRefreshVisibleTextInferenceClearsRunningCommandOverrideAtIdlePrompt() async throws {
        try await MainActor.run {
            let (store, service, workspaceID, panelID, visibleTextStore) = try makeActivityInferenceFixture()
            let repoPath = "/tmp/restored-running-command"

            XCTAssertTrue(
                store.send(
                    .updateTerminalPanelMetadata(
                        panelID: panelID,
                        title: repoPath,
                        cwd: repoPath
                    )
                )
            )

            visibleTextStore.textByPanelID[panelID] = """
            dev@host ~/repo % emptyos dev --port 3913
            Status: running
            """
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )
            XCTAssertEqual(service.panelDisplayTitleOverride(for: panelID), "emptyos dev --port 3913")

            visibleTextStore.textByPanelID[panelID] = "dev@host ~/repo %"
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )

            XCTAssertNil(service.panelDisplayTitleOverride(for: panelID))
            try StateValidator.validate(store.state)
        }
    }

    func testRefreshVisibleTextInferenceDoesNotOverrideCustomTitleWithRunningCommand() async throws {
        try await MainActor.run {
            let (store, service, workspaceID, panelID, visibleTextStore) = try makeActivityInferenceFixture()

            XCTAssertTrue(
                store.send(
                    .updateTerminalPanelMetadata(
                        panelID: panelID,
                        title: "Dev Server",
                        cwd: "/Users/dev/repo"
                    )
                )
            )

            visibleTextStore.textByPanelID[panelID] = """
            dev@host ~/repo % emptyos dev --port 3913
            Status: running
            """
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )

            XCTAssertNil(service.panelDisplayTitleOverride(for: panelID))
            XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).title, "Dev Server")
            try StateValidator.validate(store.state)
        }
    }

    func testRefreshVisibleTextInferenceClearsRunningCommandOverrideWhenSemanticTitleArrives() async throws {
        try await MainActor.run {
            let (store, service, workspaceID, panelID, visibleTextStore) = try makeActivityInferenceFixture()
            let repoPath = "/tmp/restored-running-command"

            XCTAssertTrue(
                store.send(
                    .updateTerminalPanelMetadata(
                        panelID: panelID,
                        title: repoPath,
                        cwd: repoPath
                    )
                )
            )

            visibleTextStore.textByPanelID[panelID] = """
            dev@host ~/repo % emptyos dev --port 3913
            Status: running
            """
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )
            XCTAssertEqual(service.panelDisplayTitleOverride(for: panelID), "emptyos dev --port 3913")

            XCTAssertTrue(
                store.send(
                    .updateTerminalPanelMetadata(
                        panelID: panelID,
                        title: "emptyos dev --port 3913",
                        cwd: nil
                    )
                )
            )
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )

            XCTAssertNil(service.panelDisplayTitleOverride(for: panelID))
            XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).title, "emptyos dev --port 3913")
            try StateValidator.validate(store.state)
        }
    }

    func testRefreshVisibleTextInferencePublishesWorkspaceSubtextForRunningAgent() async throws {
        try await MainActor.run {
            let (store, service, workspaceID, panelID, visibleTextStore) = try makeActivityInferenceFixture()

            visibleTextStore.textByPanelID[panelID] = """
            dev@host ~/repo % codex
            OpenAI Codex (v0.1)
            Applying diff...
            """
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )

            XCTAssertEqual(service.workspaceActivitySubtext(for: workspaceID), "1 Codex · 1 running")
            try StateValidator.validate(store.state)
        }
    }

    func testSynchronizeLivePanelsPrunesWorkspaceSubtext() async throws {
        try await MainActor.run {
            let (store, service, workspaceID, panelID, visibleTextStore) = try makeActivityInferenceFixture()

            visibleTextStore.textByPanelID[panelID] = """
            dev@host ~/repo % codex
            OpenAI Codex (v0.1)
            Applying diff...
            """
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: [panelID: workspaceID],
                backgroundPanelWorkspaceIDs: [:]
            )
            XCTAssertEqual(service.workspaceActivitySubtext(for: workspaceID), "1 Codex · 1 running")

            service.synchronizeLivePanels([], liveWorkspaceIDs: [])

            XCTAssertNil(service.workspaceActivitySubtext(for: workspaceID))
            XCTAssertNil(service.panelDisplayTitleOverride(for: panelID))
            try StateValidator.validate(store.state)
        }
    }

    func testSynchronizeLivePanelsRecomputesWorkspaceSubtextForRemainingPanels() async throws {
        try await MainActor.run {
            let state = try makeSplitFixtureState()
            let store = AppStore(state: state, persistTerminalFontPreference: false)
            let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
            let panelIDs = Array(try XCTUnwrap(store.selectedWorkspace?.panels.keys)).sorted {
                $0.uuidString < $1.uuidString
            }
            XCTAssertEqual(panelIDs.count, 2)

            let visibleTextStore = VisibleTextStore()
            for panelID in panelIDs {
                visibleTextStore.textByPanelID[panelID] = """
                dev@host ~/repo % codex
                OpenAI Codex (v0.1)
                Applying diff...
                """
            }
            let service = makeActivityInferenceService(visibleTextStore: visibleTextStore)

            let trackedPanels = Dictionary(uniqueKeysWithValues: panelIDs.map { ($0, workspaceID) })
            service.refreshVisibleTextInference(
                state: store.state,
                selectedPanelWorkspaceIDs: trackedPanels,
                backgroundPanelWorkspaceIDs: [:]
            )
            XCTAssertEqual(service.workspaceActivitySubtext(for: workspaceID), "2 Codex · 2 running")

            let survivingPanelID = try XCTUnwrap(panelIDs.first)
            service.synchronizeLivePanels(
                Set([survivingPanelID]),
                liveWorkspaceIDs: Set([workspaceID])
            )

            XCTAssertEqual(service.workspaceActivitySubtext(for: workspaceID), "1 Codex · 1 running")
            try StateValidator.validate(store.state)
        }
    }
}

@MainActor
private func makeActivityInferenceFixture()
throws -> (
    store: AppStore,
    service: TerminalActivityInferenceService,
    workspaceID: UUID,
    panelID: UUID,
    visibleTextStore: VisibleTextStore
) {
    let state = AppState.bootstrap()
    let store = AppStore(state: state, persistTerminalFontPreference: false)
    let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
    let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
    let visibleTextStore = VisibleTextStore()
    let service = makeActivityInferenceService(visibleTextStore: visibleTextStore)
    return (store, service, workspaceID, panelID, visibleTextStore)
}

@MainActor
private func makeActivityInferenceService(
    visibleTextStore: VisibleTextStore
) -> TerminalActivityInferenceService {
    TerminalActivityInferenceService(
        readVisibleText: { panelID in
            visibleTextStore.textByPanelID[panelID]
        }
    )
}

private func terminalState(panelID: UUID, state: AppState) throws -> TerminalPanelState {
    let workspace = try XCTUnwrap(state.workspacesByID.values.first { $0.panels[panelID] != nil })
    guard case .terminal(let terminalState) = workspace.panels[panelID] else {
        XCTFail("expected terminal panel state")
        throw TestError.expectedTerminalPanel
    }
    return terminalState
}

private enum TestError: Error {
    case expectedTerminalPanel
}

@MainActor
private final class VisibleTextStore {
    var textByPanelID: [UUID: String] = [:]
}

@MainActor
private func makeSplitFixtureState() throws -> AppState {
    var state = AppState.bootstrap()
    let reducer = AppReducer()
    let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
    XCTAssertTrue(
        reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state),
        "expected split fixture creation to succeed"
    )
    return state
}
#endif
