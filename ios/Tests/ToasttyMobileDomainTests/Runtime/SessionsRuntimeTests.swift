import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class SessionsRuntimeTests: XCTestCase {
    func testRESTSeedThenOpenStillWaitsForFreshStreamSnapshot() async throws {
        let runtime = SessionsRuntime()
        let seed = snapshot(runID: runID(1), title: "REST")
        let fresh = snapshot(runID: runID(1), title: "Stream")

        var accepted = await runtime.beginConnection(generation: 1)
        XCTAssertTrue(accepted)
        accepted = await runtime.applyRESTSeed(seed, generation: 1)
        XCTAssertTrue(accepted)
        var state = await runtime.currentState()
        XCTAssertEqual(state.phase, .awaitingSocket)

        accepted = await runtime.didOpen(generation: 1)
        XCTAssertTrue(accepted)
        state = await runtime.currentState()
        XCTAssertEqual(state.phase, .awaitingFreshSnapshot)
        XCTAssertEqual(state.snapshot, seed)

        accepted = await runtime.applyStreamSnapshot(fresh, generation: 1)
        XCTAssertTrue(accepted)
        state = await runtime.currentState()
        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.snapshot, fresh)
    }

    func testStaleGenerationCannotOverwriteNewConnection() async {
        let runtime = SessionsRuntime()
        let stale = snapshot(runID: runID(1), title: "Stale")
        let current = snapshot(runID: runID(2), title: "Current")

        var accepted = await runtime.beginConnection(generation: 1)
        XCTAssertTrue(accepted)
        accepted = await runtime.beginConnection(generation: 2)
        XCTAssertTrue(accepted)
        accepted = await runtime.applyRESTSeed(stale, generation: 1)
        XCTAssertFalse(accepted)
        accepted = await runtime.applyRESTSeed(current, generation: 2)
        XCTAssertTrue(accepted)
        accepted = await runtime.didOpen(generation: 1)
        XCTAssertFalse(accepted)

        let state = await runtime.currentState()
        XCTAssertEqual(state.connectionGeneration, 2)
        XCTAssertEqual(state.snapshot, current)
        XCTAssertEqual(state.phase, .awaitingSocket)
    }

    func testReconnectSuspendAndTerminalFailureAreExplicit() async {
        let runtime = SessionsRuntime()

        var accepted = await runtime.markReconnecting(generation: 4)
        XCTAssertTrue(accepted)
        var state = await runtime.currentState()
        XCTAssertEqual(state.phase, .reconnecting)
        accepted = await runtime.suspend(generation: 5)
        XCTAssertTrue(accepted)
        state = await runtime.currentState()
        XCTAssertEqual(state.phase, .suspended)
        accepted = await runtime.failTerminally(.protocolMismatch(version: "2.0"), generation: 6)
        XCTAssertTrue(accepted)
        state = await runtime.currentState()
        XCTAssertEqual(
            state.phase,
            .terminalFailure(.protocolMismatch(version: "2.0"))
        )
    }

    func testStatesImmediatelyYieldsCurrentState() async {
        let runtime = SessionsRuntime()
        let accepted = await runtime.markReconnecting(generation: 3)
        XCTAssertTrue(accepted)

        let states = await runtime.states()
        var iterator = states.makeAsyncIterator()
        let state = await iterator.next()

        XCTAssertEqual(state?.connectionGeneration, 3)
        XCTAssertEqual(state?.phase, .reconnecting)
    }

    func testUnknownProviderAvailabilityRemainsPermanentlyReadOnly() async throws {
        let runtime = SessionsRuntime()
        let readOnly = snapshot(
            runID: runID(1),
            title: "Claude",
            provider: .claude,
            availability: .unavailable(reason: .known(.unknownProviderState))
        )

        var accepted = await runtime.beginConnection(generation: 1)
        XCTAssertTrue(accepted)
        accepted = await runtime.applyRESTSeed(readOnly, generation: 1)
        XCTAssertTrue(accepted)
        accepted = await runtime.didOpen(generation: 1)
        XCTAssertTrue(accepted)
        accepted = await runtime.applyStreamSnapshot(readOnly, generation: 1)
        XCTAssertTrue(accepted)

        let state = await runtime.currentState()
        let summary = try XCTUnwrap(state.snapshot?.conversations.first)
        XCTAssertEqual(summary.provider, .claude)
        XCTAssertEqual(summary.inputAvailability, .unavailable(reason: .known(.unknownProviderState)))
        XCTAssertFalse(summary.inputAvailability.allowsRemoteSend)
    }

    private func snapshot(
        runID: RemoteProjectionRunID,
        title: String,
        provider: AgentKind = .codex,
        availability: CompatibleInputAvailability = .openPrompt(
            epoch: RemoteInputEpoch(bindingID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        )
    ) -> CompatibleSessionListSnapshot {
        CompatibleSessionListSnapshot(
            projectionRunID: runID,
            conversations: [
                CompatibleConversationSummary(
                    conversationID: conversationID,
                    provider: provider,
                    title: title,
                    placement: RemoteConversationPlacement(),
                    cwd: nil,
                    state: .ready,
                    inputAvailability: availability,
                    projectionGeneration: 7,
                    latestSequence: 42,
                    updatedAt: Date(timeIntervalSince1970: 100)
                ),
            ],
            generatedAt: Date(timeIntervalSince1970: 101)
        )
    }

    private func runID(_ suffix: UInt8) -> RemoteProjectionRunID {
        RemoteProjectionRunID(rawValue: UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix
        )))
    }

    private var conversationID: RemoteConversationID {
        RemoteConversationID(
            rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }
}
