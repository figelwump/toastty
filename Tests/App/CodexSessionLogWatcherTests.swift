import Foundation
import XCTest
@testable import ToasttyApp

@MainActor
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
        await watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Running npm test")
        ])
    }

    func testWatcherUsesParsedReadCommandDetails() async throws {
        let events = try await recordEvents(
            from: #"{"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"exec_command_begin","call_id":"call-read","command":["/bin/zsh","-lc","nl -ba Sources/App/Terminal/TerminalRuntimeRegistry.swift"],"parsed_cmd":[{"type":"read","name":"TerminalRuntimeRegistry.swift","path":"Sources/App/Terminal/TerminalRuntimeRegistry.swift"}]}}}"#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Reading TerminalRuntimeRegistry.swift")
        ])
    }

    func testWatcherUsesParsedSearchCommandDetails() async throws {
        let events = try await recordEvents(
            from: #"{"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"exec_command_begin","call_id":"call-search","command":["rg","-n","SidebarView"],"parsed_cmd":[{"type":"search","query":"SidebarView"}]}}}"#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Searching for SidebarView")
        ])
    }

    func testWatcherUsesParsedListFilesCommandDetails() async throws {
        let events = try await recordEvents(
            from: #"{"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"exec_command_begin","call_id":"call-list","command":["rg","--files","Sources/App"],"parsed_cmd":[{"type":"list_files","path":"Sources/App"}]}}}"#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Listing files")
        ])
    }

    func testWatcherFallsBackToRawCommandWhenParsedCommandIsEmpty() async throws {
        let events = try await recordEvents(
            from: #"{"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"exec_command_begin","call_id":"call-empty","command":["npm","test"],"parsed_cmd":[]}}}"#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Running npm test")
        ])
    }

    func testWatcherFallsBackToRawCommandWhenParsedCommandTypeIsUnknown() async throws {
        let events = try await recordEvents(
            from: #"{"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"exec_command_begin","call_id":"call-unknown","command":["npm","test"],"parsed_cmd":[{"type":"unknown","query":"SidebarView"}]}}}"#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Running npm test")
        ])
    }

    func testWatcherFallsBackToGenericCommandDetailWhenExecCommandHasNoUsableDetails() async throws {
        let events = try await recordEvents(
            from: #"{"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"exec_command_begin","call_id":"call-generic","parsed_cmd":[{"type":"unknown"}]}}}"#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Running a shell command")
        ])
    }

    func testWatcherParsesPatchApplyBeginSingleFile() async throws {
        let events = try await recordEvents(
            from: #"{"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"patch_apply_begin","call_id":"call-patch-single","changes":{"/Users/vishal/GiantThings/repos/toastty/Sources/App/Agents/CodexSessionLogWatcher.swift":{"type":"update","unified_diff":"@@ -1 +1 @@"}}}}}"#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Editing CodexSessionLogWatcher.swift")
        ])
    }

    func testWatcherParsesPatchApplyBeginMultipleFiles() async throws {
        let events = try await recordEvents(
            from: #"{"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"patch_apply_begin","call_id":"call-patch-multi","changes":{"/tmp/B.swift":{"type":"update","unified_diff":"@@ -1 +1 @@"},"/tmp/A.swift":{"type":"update","unified_diff":"@@ -1 +1 @@"}}}}}"#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Editing A.swift and 1 more file")
        ])
    }

    func testWatcherFallsBackWhenPatchApplyChangesAreEmpty() async throws {
        let events = try await recordEvents(
            from: #"{"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"patch_apply_begin","call_id":"call-patch-empty","changes":{}}}}"#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Editing files")
        ])
    }

    func testWatcherFallsBackWhenPatchApplyChangesAreMalformed() async throws {
        let events = try await recordEvents(
            from: #"{"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"patch_apply_begin","call_id":"call-patch-malformed","changes":[]}}}"#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Editing files")
        ])
    }

    func testWatcherDeduplicatesRepeatedPatchApplyBeginEvents() async throws {
        let events = try await recordEvents(
            from:
                """
                {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"patch_apply_begin","call_id":"call-patch-repeat","changes":{"/tmp/A.swift":{"type":"update","unified_diff":"@@ -1 +1 @@"}}}}}
                {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"patch_apply_begin","call_id":"call-patch-repeat","changes":{"/tmp/A.swift":{"type":"update","unified_diff":"@@ -1 +1 @@"}}}}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Editing A.swift")
        ])
    }

    func testWatcherTreatsExecAndPatchEventsWithSameCallIDAsDistinct() async throws {
        let events = try await recordEvents(
            from:
                """
                {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"exec_command_begin","call_id":"call-shared","command":["npm","test"]}}}
                {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"patch_apply_begin","call_id":"call-shared","changes":{"/tmp/A.swift":{"type":"update","unified_diff":"@@ -1 +1 @@"}}}}}
                """,
            expectedCount: 2
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "Running npm test"),
            CodexSessionLogEvent(kind: .turnStarted, detail: "Editing A.swift")
        ])
    }

    func testWatcherIgnoresContextCompactedEvents() async throws {
        let events = try await recordEvents(
            from: #"{"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"context_compacted"}}}"#,
            expectedCount: 0
        )

        XCTAssertTrue(events.isEmpty)
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

        await watcher.stop()
        await fulfillment(of: [finalEvent], timeout: 1)

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .approvalNeeded, detail: "Choose a path")
        ])
    }

    func testWatcherParsesTurnAbortedEvents() async throws {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()
        let abortedEvent = expectation(description: "Turn aborted event arrives")
        abortedEvent.assertForOverFulfill = true

        let watcher = CodexSessionLogWatcher(
            logURL: logURL,
            pollIntervalNanoseconds: 10_000_000
        ) { event in
            await recorder.append(event)
            abortedEvent.fulfill()
        }

        watcher.start()
        try append(
            #"{"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-2","msg":{"type":"turn_aborted","reason":"interrupted"}}}"# + "\n",
            to: logURL
        )

        await fulfillment(of: [abortedEvent], timeout: 1)
        await watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnAborted, detail: "Ready for prompt")
        ])
    }

    func testWatcherParsesTaskCompleteEvents() async throws {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()
        let completionEvent = expectation(description: "Task complete event arrives")
        completionEvent.assertForOverFulfill = true

        let watcher = CodexSessionLogWatcher(
            logURL: logURL,
            pollIntervalNanoseconds: 10_000_000
        ) { event in
            await recorder.append(event)
            completionEvent.fulfill()
        }

        watcher.start()
        try append(
            #"{"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-4","msg":{"type":"task_complete","last_agent_message":"Finished updating the launch path."}}}"# + "\n",
            to: logURL
        )

        await fulfillment(of: [completionEvent], timeout: 1)
        await watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .taskCompleted, detail: "Finished updating the launch path.")
        ])
    }

    func testWatcherParsesUserPromptPreviewEvents() async throws {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()
        let promptEvent = expectation(description: "Prompt preview event arrives")
        promptEvent.assertForOverFulfill = true

        let watcher = CodexSessionLogWatcher(
            logURL: logURL,
            pollIntervalNanoseconds: 10_000_000
        ) { event in
            await recorder.append(event)
            promptEvent.fulfill()
        }

        watcher.start()
        try append(
            #"{"dir":"to_tui","kind":"codex_event","payload":{"id":"turn-3","msg":{"type":"user_message","message":"summarize skills in here"}}}"# + "\n",
            to: logURL
        )

        await fulfillment(of: [promptEvent], timeout: 1)
        await watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "summarize skills in here")
        ])
    }

    func testWatcherParsesCurrentCodexUserTurnOperationEvents() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-03-27T18:46:23.170Z","dir":"from_tui","kind":"op","payload":{"type":"user_turn","items":[{"type":"text","text":"Investigate why cdx tracking is stale in Toastty"}],"cwd":"/tmp/workspace"}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Investigate why cdx tracking is stale in Toastty"
            )
        ])
    }

    func testWatcherIgnoresRepeatedCurrentCodexUserTurnOperationEvents() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-03-27T18:46:23.170Z","dir":"from_tui","kind":"op","payload":{"type":"user_turn","items":[{"type":"text","text":"Investigate why cdx tracking is stale in Toastty"}]}}
                {"ts":"2026-03-27T18:46:23.170Z","dir":"from_tui","kind":"op","payload":{"type":"user_turn","items":[{"type":"text","text":"Investigate why cdx tracking is stale in Toastty"}]}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Investigate why cdx tracking is stale in Toastty"
            )
        ])
    }

    func testWatcherStripsNulBytesBeforeParsingLogLines() async throws {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()
        let completionEvent = expectation(description: "Task complete event arrives from NUL-heavy line")
        completionEvent.assertForOverFulfill = true

        let watcher = CodexSessionLogWatcher(
            logURL: logURL,
            pollIntervalNanoseconds: 10_000_000
        ) { event in
            await recorder.append(event)
            completionEvent.fulfill()
        }

        watcher.start()

        let rawLine = #"{"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-nul","msg":{"type":"task_complete","last_agent_message":"Finished updating the launch path."}}}"#
        var nulHeavyLine = Data()
        for byte in rawLine.utf8 {
            nulHeavyLine.append(byte)
            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: ":") {
                nulHeavyLine.append(0)
            }
        }
        nulHeavyLine.append(UInt8(ascii: "\n"))

        try append(nulHeavyLine, to: logURL)

        await fulfillment(of: [completionEvent], timeout: 1)
        await watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .taskCompleted, detail: "Finished updating the launch path.")
        ])
    }

    func testWatcherBuffersSplitLogLineAcrossWrites() async throws {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()
        let promptEvent = expectation(description: "Prompt event arrives after completing split line")
        promptEvent.assertForOverFulfill = true

        let watcher = CodexSessionLogWatcher(
            logURL: logURL,
            pollIntervalNanoseconds: 10_000_000
        ) { event in
            await recorder.append(event)
            promptEvent.fulfill()
        }

        watcher.start()

        let line =
            #"{"ts":"2026-03-27T18:46:23.170Z","dir":"from_tui","kind":"op","payload":{"type":"user_turn","items":[{"type":"text","text":"Investigate split writes in the Codex log watcher"}]}}"#
        let lineData = Data(line.utf8)
        let splitIndex = lineData.count / 2

        try append(lineData.prefix(splitIndex), to: logURL)
        try await Task.sleep(nanoseconds: 100_000_000)
        let eventsAfterFirstWrite = await recorder.snapshot()
        XCTAssertEqual(eventsAfterFirstWrite, [])

        var trailingData = Data(lineData.dropFirst(splitIndex))
        trailingData.append(UInt8(ascii: "\n"))
        try append(trailingData, to: logURL)

        await fulfillment(of: [promptEvent], timeout: 1)
        await watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Investigate split writes in the Codex log watcher"
            )
        ])
    }

    func testWatcherDeduplicatesRepeatedUserPromptPreviewEvents() async throws {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()
        let promptEvent = expectation(description: "Prompt preview event arrives once")
        promptEvent.assertForOverFulfill = true

        let watcher = CodexSessionLogWatcher(
            logURL: logURL,
            pollIntervalNanoseconds: 10_000_000
        ) { event in
            await recorder.append(event)
            promptEvent.fulfill()
        }

        watcher.start()
        try append(
            """
            {"dir":"to_tui","kind":"codex_event","payload":{"id":"turn-3","msg":{"type":"user_message","message":"summarize skills in here"}}}
            {"dir":"to_tui","kind":"codex_event","payload":{"id":"turn-3","msg":{"type":"user_message","message":"summarize skills in here"}}}
            """,
            to: logURL
        )

        await fulfillment(of: [promptEvent], timeout: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        await watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnStarted, detail: "summarize skills in here")
        ])
    }

    func testWatcherDrainsTurnAbortedEventOnImmediateStop() async throws {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()

        let watcher = CodexSessionLogWatcher(
            logURL: logURL,
            pollIntervalNanoseconds: 1_000_000_000
        ) { event in
            await recorder.append(event)
        }

        watcher.start()
        try append(
            #"{"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-5","msg":{"type":"turn_aborted","reason":"interrupted"}}}"# + "\n",
            to: logURL
        )

        await watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnAborted, detail: "Ready for prompt")
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
        try append(Data(string.utf8), to: url)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func recordEvents(
        from contents: String,
        expectedCount: Int,
        pollIntervalNanoseconds: UInt64 = 10_000_000
    ) async throws -> [CodexSessionLogEvent] {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()
        let eventsExpectation = expectedCount > 0
            ? expectation(description: "Expected watcher events arrive")
            : nil
        eventsExpectation?.expectedFulfillmentCount = expectedCount
        eventsExpectation?.assertForOverFulfill = true

        let watcher = CodexSessionLogWatcher(logURL: logURL, pollIntervalNanoseconds: pollIntervalNanoseconds) { event in
            await recorder.append(event)
            eventsExpectation?.fulfill()
        }

        watcher.start()
        let terminatedContents = contents.hasSuffix("\n") ? contents : contents + "\n"
        try append(terminatedContents, to: logURL)

        if let eventsExpectation {
            await fulfillment(of: [eventsExpectation], timeout: 1)
        } else {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        await watcher.stop()
        return await recorder.snapshot()
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
