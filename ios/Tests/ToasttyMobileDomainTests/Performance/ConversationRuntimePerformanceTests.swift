import Darwin
import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class ConversationRuntimePerformanceTests: XCTestCase {
    private static let eventCount = 5_000
    private static let unknownEventSequence = (eventCount / 2) + 1
    private static let elapsedTimeBudget = Duration.seconds(1)
    private static let incrementalResidentMemoryBudget: UInt64 = 100 * 1_024 * 1_024

    func testFiveThousandEventDecodeAndReduceStaysWithinProvisionalBudgets() async throws {
        let envelopeData = try autoreleasepool {
            try makeCanonicalEventsEnvelope()
        }
        let runtime = ConversationRuntime(conversationID: conversationID)
        let decoder = GatewayCompatibilityDecoder()
        let clock = ContinuousClock()
        let residentMemoryBefore = try residentMemoryBytes()

        let start = clock.now
        let response = try decoder.decodeEventsResponse(envelopeData)
        let page: CompatibleConversationEventPage
        switch response {
        case .page(let decodedPage):
            page = decodedPage
        case .resnapshotRequired, .conversationNotFound:
            return XCTFail("Expected a decoded event page")
        }

        let beganCatchUp = await runtime.beginCatchUp(connectionGeneration: 1)
        let directive = await runtime.applyREST(page, connectionGeneration: 1)
        let finishedCatchUp = await runtime.finishCatchUp(connectionGeneration: 1)
        let state = await runtime.currentState()
        let elapsed = start.duration(to: clock.now)
        let residentMemoryAfter = try residentMemoryBytes()
        let incrementalResidentMemory = residentMemoryAfter >= residentMemoryBefore
            ? residentMemoryAfter - residentMemoryBefore
            : 0

        print(
            "TOASTTY_DOMAIN_PERFORMANCE events=\(Self.eventCount) "
                + "elapsed=\(elapsed) incrementalResidentBytes=\(incrementalResidentMemory)"
        )

        XCTAssertTrue(beganCatchUp)
        XCTAssertEqual(directive, .none)
        XCTAssertTrue(finishedCatchUp)
        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.cursor?.afterSequence, UInt64(Self.eventCount))
        XCTAssertEqual(state.latestSequence, UInt64(Self.eventCount))
        XCTAssertEqual(state.events.count, Self.eventCount - 1)
        XCTAssertFalse(state.events.contains { $0.sequence == UInt64(Self.unknownEventSequence) })
        XCTAssertLessThanOrEqual(
            elapsed,
            Self.elapsedTimeBudget,
            "Decode + reduce took \(elapsed); budget is \(Self.elapsedTimeBudget)"
        )
        XCTAssertLessThanOrEqual(
            incrementalResidentMemory,
            Self.incrementalResidentMemoryBudget,
            "Decode + reduce retained \(incrementalResidentMemory) bytes; budget is \(Self.incrementalResidentMemoryBudget) bytes"
        )
    }

    private func makeCanonicalEventsEnvelope() throws -> Data {
        var events: [[String: Any]] = []
        events.reserveCapacity(Self.eventCount)

        for sequence in 1...Self.eventCount {
            let kind: String
            let payload: [String: Any]
            if sequence == Self.unknownEventSequence {
                kind = "future_optional_event"
                payload = ["future": true]
            } else {
                kind = "assistant_message"
                payload = [
                    "phase": "final",
                    "text": "Deterministic performance event \(sequence)",
                ]
            }
            events.append([
                "conversationID": conversationID.rawValue.uuidString,
                "eventID": "performance-event-\(sequence)",
                "kind": kind,
                "payload": payload,
                "provider": "codex",
                "schemaVersion": ConversationEvent.currentSchemaVersion,
                "sequence": sequence,
                "timestamp": "2026-08-11T12:00:00.000Z",
            ])
        }

        let envelope: [String: Any] = [
            "outcome": "page",
            "page": [
                "conversationID": conversationID.rawValue.uuidString,
                "events": events,
                "firstAvailableSequence": 1,
                "historyTruncated": false,
                "latestSequence": Self.eventCount,
                "projectionGeneration": 1,
                "projectionRunID": projectionRunID.rawValue.uuidString,
            ],
            "protocolVersion": RemoteGatewayProtocol.version,
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private func residentMemoryBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { integerPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    integerPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw ResidentMemoryError.taskInfoFailed(result)
        }
        return UInt64(info.resident_size)
    }

    private var conversationID: RemoteConversationID {
        RemoteConversationID(
            rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }

    private var projectionRunID: RemoteProjectionRunID {
        RemoteProjectionRunID(
            rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
    }
}

private enum ResidentMemoryError: Error {
    case taskInfoFailed(kern_return_t)
}
