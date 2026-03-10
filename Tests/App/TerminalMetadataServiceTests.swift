#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalMetadataServiceTests: XCTestCase {
    func testRequestImmediateWorkingDirectoryRefreshRetriesUntilProcessResolverSucceeds() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        XCTAssertTrue(
            store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: "/tmp/stale"))
        )

        var resolveAttemptCount = 0
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in
                resolveAttemptCount += 1
                return resolveAttemptCount >= 3 ? "/tmp/fresh" : nil
            },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        service.requestImmediateWorkingDirectoryRefresh(
            panelID: panelID,
            source: "surface_create_process"
        )
        await settleMetadataTasks()

        XCTAssertEqual(resolveAttemptCount, 3)
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/fresh")
        try StateValidator.validate(store.state)
    }

    func testRequestImmediateWorkingDirectoryRefreshStopsAfterBoundedRetriesWithoutMutation() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        XCTAssertTrue(
            store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: "/tmp/stale"))
        )

        var resolveAttemptCount = 0
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in
                resolveAttemptCount += 1
                return nil
            },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        service.requestImmediateWorkingDirectoryRefresh(
            panelID: panelID,
            source: "surface_create_process"
        )
        await settleMetadataTasks()

        XCTAssertEqual(
            resolveAttemptCount,
            TerminalMetadataService.immediateProcessRefreshAttemptCount
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/stale")
        try StateValidator.validate(store.state)
    }
}

@MainActor
private func terminalState(panelID: UUID, state: AppState) throws -> TerminalPanelState {
    let workspace = try XCTUnwrap(state.workspacesByID.values.first { $0.panels[panelID] != nil })
    guard case .terminal(let terminalState) = workspace.panels[panelID] else {
        XCTFail("expected terminal panel state")
        throw TerminalMetadataServiceTestError.expectedTerminalPanel
    }
    return terminalState
}

@MainActor
private func settleMetadataTasks(iterations: Int = 12) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
}

private enum TerminalMetadataServiceTestError: Error {
    case expectedTerminalPanel
}
#endif
