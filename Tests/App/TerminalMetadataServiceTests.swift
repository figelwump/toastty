#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalMetadataServiceTests: XCTestCase {
    func testNativeGhosttyCWDDisablesProcessFallbackUpdates() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in "/tmp/wrong" },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/native"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        XCTAssertTrue(service.prefersNativeCWDSignal(panelID: panelID))
        XCTAssertFalse(service.shouldRunProcessCWDFallbackPoll(panelID: panelID, now: .distantFuture))
        XCTAssertNil(
            service.refreshWorkingDirectoryFromProcessIfNeeded(
                panelID: panelID,
                source: "process_poll"
            )
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/native")
        try StateValidator.validate(store.state)
    }

    func testImmediateProcessRefreshStopsRetryingAfterNativeGhosttyCWDSignal() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

        var resolveAttemptCount = 0
        let delayGate = AsyncGate()
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in
                resolveAttemptCount += 1
                return nil
            },
            processRefreshRetryDelay: { _ in
                await delayGate.wait()
            }
        )

        service.requestImmediateWorkingDirectoryRefresh(
            panelID: panelID,
            source: "surface_create_process"
        )
        await waitUntil { resolveAttemptCount == 1 }

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/native"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        await delayGate.open()
        await settleMetadataTasks()

        XCTAssertEqual(resolveAttemptCount, 1)
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/native")
        try StateValidator.validate(store.state)
    }

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

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard isOpen == false else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private enum TerminalMetadataServiceTestError: Error {
    case expectedTerminalPanel
}
#endif
