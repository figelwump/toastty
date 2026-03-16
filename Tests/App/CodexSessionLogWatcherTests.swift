import Foundation
import XCTest
@testable import ToasttyApp

final class CodexSessionLogWatcherTests: XCTestCase {
    func testWatcherDeduplicatesRepeatedExecCommandEvents() async throws {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()
        let firstEvent = expectation(description: "First event arrives")
        firstEvent.assertForOverFulfill = true

        let watcher = CodexSessionLogWatcher(
            logURL: logURL,
            pollIntervalNanoseconds: 10_000_000
        ) { event in
            await recorder.append(event)
            firstEvent.fulfill()
        }

        watcher.start()
        try append(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-1","msg":{"type":"exec_command_begin","command":["npm","test"]}}}
            {"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-1","msg":{"type":"exec_command_begin","command":["npm","test"]}}}
            """,
            to: logURL
        )

        await fulfillment(of: [firstEvent], timeout: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Running npm test")
        ])
    }

    func testWatcherFlushesFinalBufferedLineOnStop() async throws {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()
        let finalEvent = expectation(description: "Buffered final event flushes on stop")
        finalEvent.assertForOverFulfill = true

        let watcher = CodexSessionLogWatcher(
            logURL: logURL,
            pollIntervalNanoseconds: 10_000_000
        ) { event in
            await recorder.append(event)
            finalEvent.fulfill()
        }

        watcher.start()
        try append(
            #"{"dir":"to_tui","kind":"codex_event","payload":{"approval_id":"approval-1","msg":{"type":"request_user_input","question":"Choose a path"}}}"#,
            to: logURL
        )

        try await Task.sleep(nanoseconds: 100_000_000)
        let bufferedEvents = await recorder.snapshot()
        XCTAssertTrue(bufferedEvents.isEmpty)

        watcher.stop()
        await fulfillment(of: [finalEvent], timeout: 1)

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .approvalNeeded, detail: "Choose a path")
        ])
    }

    private func makeLogURL() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-codex-watcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let logURL = directoryURL.appendingPathComponent("codex-session.jsonl", isDirectory: false)
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        return logURL
    }

    private func append(_ string: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(string.utf8))
    }
}

private actor EventRecorder {
    private var events: [CodexSessionLogEvent] = []

    func append(_ event: CodexSessionLogEvent) {
        events.append(event)
    }

    func snapshot() -> [CodexSessionLogEvent] {
        events
    }
}
