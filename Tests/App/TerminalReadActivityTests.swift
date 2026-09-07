import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

@MainActor
final class TerminalReadActivityTests: XCTestCase {
    func testRecordReadMovesRepeatReaderToFrontAndIncrementsCounts() {
        let store = TerminalReadActivityStore()
        let panelID = UUID()

        store.recordRead(panelID: panelID, sessionID: "a", label: "Claude Code", at: Date(timeIntervalSince1970: 10))
        store.recordRead(panelID: panelID, sessionID: "b", label: "Codex", at: Date(timeIntervalSince1970: 20))
        store.recordRead(panelID: panelID, sessionID: "a", label: "Claude Code", at: Date(timeIntervalSince1970: 30))

        let model = store.model(for: panelID)
        XCTAssertEqual(model.totalReadCount, 3)
        XCTAssertEqual(model.readers.map(\.sessionID), ["a", "b"])
        XCTAssertEqual(model.readers.first?.readCount, 2)
        XCTAssertEqual(model.readers.first?.lastReadAt, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(model.mostRecentReader?.label, "Claude Code")
        XCTAssertTrue(model.hasReaders)
    }

    func testUnknownCallerIsRecordedWithFallbackLabel() {
        let store = TerminalReadActivityStore()
        let panelID = UUID()

        store.recordRead(panelID: panelID, sessionID: nil, label: nil)

        let reader = store.model(for: panelID).readers.first
        XCTAssertEqual(reader?.sessionID, TerminalReadActivityStore.unknownReaderSessionID)
        XCTAssertEqual(reader?.label, TerminalReadActivityStore.unknownReaderLabel)
    }

    func testRetainReadersDropsEndedSessionsButKeepsUnknownClient() {
        let store = TerminalReadActivityStore()
        let panelID = UUID()
        store.recordRead(panelID: panelID, sessionID: "a", label: "Claude Code")
        store.recordRead(panelID: panelID, sessionID: "b", label: "Codex")
        store.recordRead(panelID: panelID, sessionID: nil, label: nil)

        store.retainReaders(liveSessionIDs: ["b"])

        let model = store.model(for: panelID)
        XCTAssertEqual(
            model.readers.map(\.sessionID),
            [TerminalReadActivityStore.unknownReaderSessionID, "b"]
        )

        store.retainReaders(liveSessionIDs: [])
        XCTAssertEqual(model.readers.map(\.sessionID), [TerminalReadActivityStore.unknownReaderSessionID])
    }

    func testSynchronizeLivePanelsDropsClosedPanels() {
        let store = TerminalReadActivityStore()
        let live = UUID()
        let closed = UUID()
        store.recordRead(panelID: live, sessionID: "a", label: "Claude Code")
        store.recordRead(panelID: closed, sessionID: "a", label: "Claude Code")

        store.synchronizeLivePanels([live])

        XCTAssertNotNil(store.existingModel(for: live))
        XCTAssertNil(store.existingModel(for: closed))
    }

    func testIndicatorStateResolution() {
        XCTAssertEqual(
            TerminalReadActivityIndicatorState.resolve(allowsAgentReads: true, hasReaders: false),
            .hidden
        )
        XCTAssertEqual(
            TerminalReadActivityIndicatorState.resolve(allowsAgentReads: true, hasReaders: true),
            .idle
        )
        XCTAssertEqual(
            TerminalReadActivityIndicatorState.resolve(allowsAgentReads: false, hasReaders: false),
            .privateToAgents
        )
        XCTAssertEqual(
            TerminalReadActivityIndicatorState.resolve(allowsAgentReads: false, hasReaders: true),
            .privateToAgents
        )
    }

    func testTooltipLinesIncludeShortcutCountAndAge() {
        let now = Date(timeIntervalSince1970: 1_000)
        let readers = [
            TerminalReadActivityReader(
                sessionID: "a",
                label: "Claude Code",
                readCount: 4,
                lastReadAt: Date(timeIntervalSince1970: 988)
            ),
            TerminalReadActivityReader(
                sessionID: "b",
                label: "Codex",
                readCount: 1,
                lastReadAt: Date(timeIntervalSince1970: 820)
            ),
        ]

        let lines = TerminalReadActivityTooltip.lines(
            readers: readers,
            shortcutNumberForSession: { $0 == "a" ? 2 : nil },
            now: now
        )

        XCTAssertEqual(
            lines,
            [
                "Read by Claude Code (⌥⇧2) · 4 reads · last 12 s ago",
                "Read by Codex · 1 read · last 3 min ago",
            ]
        )
    }

    func testRelativeAgeBuckets() {
        let now = Date(timeIntervalSince1970: 100_000)
        func age(_ secondsAgo: TimeInterval) -> String {
            TerminalReadActivityTooltip.relativeAge(from: now.addingTimeInterval(-secondsAgo), to: now)
        }
        XCTAssertEqual(age(0), "just now")
        XCTAssertEqual(age(4), "just now")
        XCTAssertEqual(age(45), "45 s ago")
        XCTAssertEqual(age(125), "2 min ago")
        XCTAssertEqual(age(7_200), "2 h ago")
        XCTAssertEqual(age(90_000), "1 d ago")
    }
}
