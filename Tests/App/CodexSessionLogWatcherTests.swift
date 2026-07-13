import CoreState
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

    func testWatcherParsesSessionConfiguredEventsAsNativeSessionUpdates() async throws {
        let events = try await recordEvents(
            from:
                """
                {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"019e316e-9f7f-7a33-aad9-33fe27b0f2cd","thread_id":"019e316e-9f7f-7a33-aad9-33fe27b0f2cd","cwd":"/tmp/repo","rollout_path":"/tmp/codex-sessions/rollout-019e316e-9f7f-7a33-aad9-33fe27b0f2cd.jsonl"}}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .sessionConfigured,
                detail: "Codex session configured",
                nativeSessionID: "019e316e-9f7f-7a33-aad9-33fe27b0f2cd",
                nativeSessionFilePath: "/tmp/codex-sessions/rollout-019e316e-9f7f-7a33-aad9-33fe27b0f2cd.jsonl"
            )
        ])
    }

    func testWatcherIgnoresSessionConfiguredEventsForInheritedSubagentSessions() async throws {
        let events = try await recordEvents(
            from:
                """
                {"dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"019e316e-9f7f-7a33-aad9-33fe27b0f2cd","thread_id":"019e316f-175b-7157-a634-765b1580294f","cwd":"/tmp/repo","rollout_path":"/tmp/codex-sessions/rollout-019e316f-175b-7157-a634-765b1580294f.jsonl"}}}
                """,
            expectedCount: 0
        )

        XCTAssertEqual(events, [])
    }

    func testWatcherAllowsRepeatedSessionConfiguredEventsForSameThreadAcrossResumeSwitches() async throws {
        let threadB = "019e316e-9f7f-7a33-aad9-33fe27b0f2cd"
        let threadC = "019e316f-175b-7157-a634-765b1580294f"
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-05-16T10:00:00.000Z","dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"\(threadB)","thread_id":"\(threadB)","cwd":"/tmp/repo","rollout_path":"/tmp/codex-sessions/rollout-\(threadB).jsonl"}}}
                {"ts":"2026-05-16T10:01:00.000Z","dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"\(threadC)","thread_id":"\(threadC)","cwd":"/tmp/repo","rollout_path":"/tmp/codex-sessions/rollout-\(threadC).jsonl"}}}
                {"ts":"2026-05-16T10:02:00.000Z","dir":"to_tui","kind":"codex_event","payload":{"msg":{"type":"session_configured","session_id":"\(threadB)","thread_id":"\(threadB)","cwd":"/tmp/repo","rollout_path":"/tmp/codex-sessions/rollout-\(threadB).jsonl"}}}
                """,
            expectedCount: 3
        )

        XCTAssertEqual(events.map(\.nativeSessionID), [threadB, threadC, threadB])
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
            #"{"dir":"to_tui","kind":"codex_event","payload":{"turn_id":"turn-4","msg":{"type":"task_complete","thread_id":"thread-root","last_agent_message":"Finished updating the launch path."}}}"# + "\n",
            to: logURL
        )

        await fulfillment(of: [completionEvent], timeout: 1)
        await watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .taskCompleted,
                detail: "Finished updating the launch path.",
                completionThreadID: "thread-root",
                completionTurnID: "turn-4"
            )
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
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "summarize skills in here",
                rootInputFingerprint: CodexInputFingerprint.fingerprint(for: "summarize skills in here"),
                rootTurnID: "turn-3"
            )
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
                detail: "Investigate why cdx tracking is stale in Toastty",
                rootInputFingerprint: CodexInputFingerprint.fingerprint(for: "Investigate why cdx tracking is stale in Toastty")
            )
        ])
    }

    func testWatcherParsesExternallyTaggedCodexUserTurnOperationEvents() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-05-01T19:12:54.834Z","dir":"from_tui","kind":"op","payload":{"UserTurn":{"items":[{"type":"text","text":"Investigate the sidebar working state","text_elements":[]}],"cwd":"/tmp/workspace"}}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Investigate the sidebar working state",
                rootInputFingerprint: CodexInputFingerprint.fingerprint(for: "Investigate the sidebar working state")
            )
        ])
    }

    func testWatcherParsesThreadGoalObjectiveAppEventsAsRootTurns() async throws {
        let objective = "implement docs/plans/meal-water-logger-v1.md with fidelity to mockups at docs/plans/v1_mockups"
        let events = try await recordEvents(
            from:
                #"""
                {"ts":"2026-05-08T03:17:50.862Z","dir":"to_tui","kind":"app_event","variant":"SetThreadGoalObjective { thread_id: ThreadId { uuid: 019e0597-141c-79b3-93d4-ac9dbfe3bdf1 }, objective: \"implement docs/plans/meal-water-logger-v1.md with fidelity to mockups at docs/plans/v1_mockups\", mode: ConfirmIfExists }"}
                """#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: objective,
                rootInputFingerprint: CodexInputFingerprint.fingerprint(for: objective),
                rootThreadID: "019e0597-141c-79b3-93d4-ac9dbfe3bdf1"
            )
        ])
    }

    func testWatcherParsesCurrentCodexUserTurnApprovalContext() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-05-27T20:00:00.000Z","dir":"from_tui","kind":"op","payload":{"type":"user_turn","turn_id":"turn-root","items":[{"type":"text","text":"Run repo checks"}],"approval_policy":"never","approvals_reviewer":"reviewer"}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Run repo checks",
                rootInputFingerprint: CodexInputFingerprint.fingerprint(for: "Run repo checks"),
                rootTurnID: "turn-root",
                approvalPolicy: "never",
                approvalsReviewer: "reviewer"
            )
        ])
    }

    func testWatcherParsesTopLevelTurnContextApprovalContext() async throws {
        let events = try await recordEvents(
            from:
                """
                {"timestamp":"2026-06-02T17:53:00.654Z","type":"turn_context","payload":{"turn_id":"turn-root","cwd":"/tmp/workspace","approval_policy":"on-request","approvals_reviewer":"auto_review"}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Responding to your prompt",
                rootTurnID: "turn-root",
                approvalPolicy: "on-request",
                approvalsReviewer: "auto_review"
            )
        ])
    }

    func testWatcherInfersTopLevelAutoReviewFromPermissionsDeveloperMessage() async throws {
        let events = try await recordEvents(
            from:
                """
                {"timestamp":"2026-06-02T17:53:00.654Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>\\n`approvals_reviewer` is `auto_review`: Sandbox escalations with require_escalated will be reviewed for compliance with the policy.\\n</permissions instructions>"}]}}
                {"timestamp":"2026-06-02T17:53:00.655Z","type":"turn_context","payload":{"turn_id":"turn-root","cwd":"/tmp/workspace","approval_policy":"on-request"}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Responding to your prompt",
                rootTurnID: "turn-root",
                approvalPolicy: "on-request",
                approvalsReviewer: "auto_review"
            )
        ])
    }

    func testWatcherDoesNotInferAutoReviewFromUnscopedDeveloperText() async throws {
        let events = try await recordEvents(
            from:
                """
                {"timestamp":"2026-06-02T17:53:00.654Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"A note can mention `approvals_reviewer` is `auto_review` without being the permissions block."}]}}
                {"timestamp":"2026-06-02T17:53:00.655Z","type":"turn_context","payload":{"turn_id":"turn-root","cwd":"/tmp/workspace","approval_policy":"on-request"}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Responding to your prompt",
                rootTurnID: "turn-root",
                approvalPolicy: "on-request"
            )
        ])
    }

    func testWatcherCarriesInferredAutoReviewAcrossTopLevelTurnContexts() async throws {
        let events = try await recordEvents(
            from:
                """
                {"timestamp":"2026-06-02T17:53:00.654Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>\\n`approvals_reviewer` is `auto_review`: Sandbox escalations with require_escalated will be reviewed for compliance with the policy.\\n</permissions instructions>"}]}}
                {"timestamp":"2026-06-02T17:53:00.655Z","type":"turn_context","payload":{"turn_id":"turn-one","cwd":"/tmp/workspace","approval_policy":"on-request"}}
                {"timestamp":"2026-06-02T17:54:00.655Z","type":"turn_context","payload":{"turn_id":"turn-two","cwd":"/tmp/workspace","approval_policy":"on-request"}}
                """,
            expectedCount: 2
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Responding to your prompt",
                rootTurnID: "turn-one",
                approvalPolicy: "on-request",
                approvalsReviewer: "auto_review"
            ),
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Responding to your prompt",
                rootTurnID: "turn-two",
                approvalPolicy: "on-request",
                approvalsReviewer: "auto_review"
            )
        ])
    }

    func testWatcherClearsInferredAutoReviewAfterPermissionsBlockWithoutReviewer() async throws {
        let events = try await recordEvents(
            from:
                """
                {"timestamp":"2026-06-02T17:53:00.654Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>\\n`approvals_reviewer` is `auto_review`: Sandbox escalations with require_escalated will be reviewed for compliance with the policy.\\n</permissions instructions>"}]}}
                {"timestamp":"2026-06-02T17:53:00.655Z","type":"turn_context","payload":{"turn_id":"turn-one","cwd":"/tmp/workspace","approval_policy":"on-request"}}
                {"timestamp":"2026-06-02T17:54:00.654Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>\\nApproval policy is currently on-request.\\n</permissions instructions>"}]}}
                {"timestamp":"2026-06-02T17:54:00.655Z","type":"turn_context","payload":{"turn_id":"turn-two","cwd":"/tmp/workspace","approval_policy":"on-request"}}
                """,
            expectedCount: 2
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Responding to your prompt",
                rootTurnID: "turn-one",
                approvalPolicy: "on-request",
                approvalsReviewer: "auto_review"
            ),
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Responding to your prompt",
                rootTurnID: "turn-two",
                approvalPolicy: "on-request"
            )
        ])
    }

    func testWatcherParsesCurrentCodexOverrideTurnContext() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-05-28T17:30:32.495Z","dir":"from_tui","kind":"op","payload":{"OverrideTurnContext":{"cwd":null,"approval_policy":"on-request","approvals_reviewer":"guardian_subagent","permission_profile":{"type":"managed"}}}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnContextUpdated,
                detail: "Codex turn context updated",
                approvalPolicy: "on-request",
                approvalsReviewer: "guardian_subagent"
            )
        ])
    }

    func testWatcherParsesCurrentCodexOverrideTurnContextNullsAsContextClear() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-05-28T17:30:32.495Z","dir":"from_tui","kind":"op","payload":{"OverrideTurnContext":{"approval_policy":null,"approvals_reviewer":null}}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnContextUpdated,
                detail: "Codex turn context updated",
                approvalPolicyField: .null,
                approvalsReviewerField: .null
            )
        ])
    }

    func testWatcherTreatsNullUserTurnReviewerAsUnspecified() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-05-28T19:56:55.411Z","dir":"from_tui","kind":"op","payload":{"UserTurn":{"items":[{"type":"text","text":"go ahead","text_elements":[]}],"cwd":"/tmp/workspace","approval_policy":"on-request","approvals_reviewer":null}}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "go ahead",
                rootInputFingerprint: CodexInputFingerprint.fingerprint(for: "go ahead"),
                approvalPolicy: "on-request"
            )
        ])
    }

    func testWatcherIgnoresThreadGoalMenuOpenAppEvents() async throws {
        let events = try await recordEvents(
            from:
                #"{"ts":"2026-05-08T03:17:33.351Z","dir":"to_tui","kind":"app_event","variant":"OpenThreadGoalMenu { thread_id: ThreadId { uuid: 019e0597-141c-79b3-93d4-ac9dbfe3bdf1 } }"}"#,
            expectedCount: 0
        )

        XCTAssertEqual(events, [])
    }

    func testWatcherParsesCurrentCodexInterruptOperationEvents() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-04-13T23:55:37.876Z","dir":"from_tui","kind":"op","payload":{"type":"interrupt"}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnAborted, detail: "Ready for prompt")
        ])
    }

    func testWatcherParsesExternallyTaggedCodexInterruptOperationEvents() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-05-01T19:12:03.577Z","dir":"from_tui","kind":"op","payload":"Interrupt"}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnAborted, detail: "Ready for prompt")
        ])
    }

    func testWatcherDeduplicatesRepeatedCurrentCodexInterruptOperationEvents() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-04-13T23:55:37.876Z","dir":"from_tui","kind":"op","payload":{"type":"interrupt"}}
                {"ts":"2026-04-13T23:55:37.876Z","dir":"from_tui","kind":"op","payload":{"type":"interrupt"}}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnAborted, detail: "Ready for prompt")
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
                detail: "Investigate why cdx tracking is stale in Toastty",
                rootInputFingerprint: CodexInputFingerprint.fingerprint(for: "Investigate why cdx tracking is stale in Toastty")
            )
        ])
    }

    func testWatcherParsesCurrentCodexHistoryInsertEvents() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-03-27T18:46:24.000Z","dir":"to_tui","kind":"insert_history_cell","lines":3}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .historyUpdated, detail: "History updated")
        ])
    }

    func testWatcherDeduplicatesRepeatedCurrentCodexHistoryInsertEvents() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-03-27T18:46:24.000Z","dir":"to_tui","kind":"insert_history_cell","lines":1}
                {"ts":"2026-03-27T18:46:24.000Z","dir":"to_tui","kind":"insert_history_cell","lines":1}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .historyUpdated, detail: "History updated")
        ])
    }

    func testWatcherCoalescesCurrentCodexHistoryInsertBurstIntoSingleRefreshEvent() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-03-27T18:46:24.000Z","dir":"to_tui","kind":"insert_history_cell","lines":8}
                {"ts":"2026-03-27T18:46:24.001Z","dir":"to_tui","kind":"insert_history_cell","lines":7}
                {"ts":"2026-03-27T18:46:24.002Z","dir":"to_tui","kind":"insert_history_cell","lines":1}
                {"ts":"2026-03-27T18:46:24.003Z","dir":"to_tui","kind":"insert_history_cell","lines":15}
                """,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .historyUpdated, detail: "History updated")
        ])
    }

    func testWatcherEmitsTurnStartedBeforeHistoryRefreshFromSameWrite() async throws {
        let events = try await recordEvents(
            from:
                """
                {"ts":"2026-03-27T18:46:24.000Z","dir":"to_tui","kind":"insert_history_cell","lines":3}
                {"ts":"2026-03-27T18:46:24.010Z","dir":"from_tui","kind":"op","payload":{"type":"user_turn","items":[{"type":"text","text":"Run repo checks"}]}}
                """,
            expectedCount: 2
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "Run repo checks",
                rootInputFingerprint: CodexInputFingerprint.fingerprint(for: "Run repo checks")
            ),
            CodexSessionLogEvent(kind: .historyUpdated, detail: "History updated")
        ])
    }

    func testWatcherEmitsHistoryRefreshesForSeparateWrites() async throws {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()
        let historyEvents = expectation(description: "History refresh events arrive across separate writes")
        historyEvents.expectedFulfillmentCount = 2
        historyEvents.assertForOverFulfill = true

        let watcher = CodexSessionLogWatcher(
            logURL: logURL,
            pollIntervalNanoseconds: 10_000_000
        ) { event in
            guard event.kind == .historyUpdated else {
                return
            }
            await recorder.append(event)
            historyEvents.fulfill()
        }

        watcher.start()
        try append(
            #"{"ts":"2026-03-27T18:46:24.000Z","dir":"to_tui","kind":"insert_history_cell","lines":3}"# + "\n",
            to: logURL
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        try append(
            #"{"ts":"2026-03-27T18:46:25.000Z","dir":"to_tui","kind":"insert_history_cell","lines":2}"# + "\n",
            to: logURL
        )
        await fulfillment(of: [historyEvents], timeout: 1, enforceOrder: true)
        await watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .historyUpdated, detail: "History updated"),
            CodexSessionLogEvent(kind: .historyUpdated, detail: "History updated")
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
            CodexSessionLogEvent(
                kind: .taskCompleted,
                detail: "Finished updating the launch path.",
                completionTurnID: "turn-nul"
            )
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
                detail: "Investigate split writes in the Codex log watcher",
                rootInputFingerprint: CodexInputFingerprint.fingerprint(
                    for: "Investigate split writes in the Codex log watcher"
                )
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
            CodexSessionLogEvent(
                kind: .turnStarted,
                detail: "summarize skills in here",
                rootInputFingerprint: CodexInputFingerprint.fingerprint(for: "summarize skills in here"),
                rootTurnID: "turn-3"
            )
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

    func testWatcherDrainsCurrentCodexInterruptEventOnImmediateStop() async throws {
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
            #"{"ts":"2026-04-13T23:55:37.876Z","dir":"from_tui","kind":"op","payload":{"type":"interrupt"}}"# + "\n",
            to: logURL
        )

        await watcher.stop()

        let events = await recorder.snapshot()
        XCTAssertEqual(events, [
            CodexSessionLogEvent(kind: .turnAborted, detail: "Ready for prompt")
        ])
    }

    func testWatcherIgnoresMultiAgentEntriesBeforeCutoff() async throws {
        // Entries at 05:41 predate the cutoff; the spawn at 06:10 does not.
        let cutoff = ISO8601DateFormatter().date(from: "2026-07-09T06:00:00Z")!
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp": "2026-07-09T05:41:47.374Z", "type": "response_item", "payload": {"type": "function_call", "name": "spawn_agent", "namespace": "multi_agent_v1", "arguments": "{\"agent_type\":\"default\",\"message\":\"stale spawn\"}", "call_id": "call_stale"}}
                {"timestamp": "2026-07-09T05:41:47.881Z", "type": "response_item", "payload": {"type": "function_call_output", "call_id": "call_stale", "output": "{\"agent_id\":\"stale-agent-id\",\"nickname\":\"Stale\"}"}}
                {"timestamp": "2026-07-09T06:10:01.000Z", "type": "response_item", "payload": {"type": "function_call", "name": "spawn_agent", "namespace": "multi_agent_v1", "arguments": "{\"agent_type\":\"default\",\"message\":\"fresh spawn\"}", "call_id": "call_fresh"}}
                {"timestamp": "2026-07-09T06:10:02.000Z", "type": "response_item", "payload": {"type": "function_call_output", "call_id": "call_fresh", "output": "{\"agent_id\":\"fresh-agent-id\",\"nickname\":\"Fresh\"}"}}
                """#,
            expectedCount: 1,
            multiAgentEventCutoff: cutoff
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .backgroundActivityStarted,
                detail: "Started Fresh",
                backgroundActivity: CodexSessionBackgroundActivity(
                    activityID: "fresh-agent-id",
                    hookActivityID: "fresh-agent-id",
                    spawnToolUseID: "call_fresh",
                    kind: .subagent,
                    displayName: "Fresh",
                    command: "fresh spawn"
                )
            ),
        ])
    }

    func testWatcherParsesCurrentCollaborationLifecycle() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-12T18:44:10.355Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","namespace":"collaboration","arguments":"{\"message\":\"Inspect the scroll implementation and report risks\",\"task_name\":\"scroll_implementation\"}","call_id":"call_spawn"}}
                {"timestamp":"2026-07-12T18:44:11.355Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_spawn","occurred_at_ms":1783881851355,"agent_thread_id":"thread-1","agent_path":"/root/scroll_implementation","kind":"started"}}
                {"timestamp":"2026-07-12T18:44:11.356Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_spawn","output":"{\"task_name\":\"/root/scroll_implementation\"}"}}
                {"timestamp":"2026-07-12T18:46:28.517Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_message","occurred_at_ms":1783881988517,"agent_thread_id":"thread-1","agent_path":"/root/scroll_implementation","kind":"interacted"}}
                {"timestamp":"2026-07-12T18:46:54.952Z","type":"response_item","payload":{"type":"agent_message","author":"/root/scroll_implementation","recipient":"/root","content":[{"type":"input_text","text":"Message Type: MESSAGE\nTask name: /root"}]}}
                {"timestamp":"2026-07-12T18:49:54.952Z","type":"response_item","payload":{"type":"agent_message","author":"/root/scroll_implementation","recipient":"/root","content":[{"type":"input_text","text":"Message Type: FINAL_ANSWER\nTask name: /root"}]}}
                """#,
            expectedCount: 2
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .backgroundActivityStarted,
                detail: "Started scroll_implementation",
                backgroundActivity: CodexSessionBackgroundActivity(
                    activityID: "/root/scroll_implementation",
                    hookActivityID: "thread-1",
                    spawnToolUseID: "call_spawn",
                    kind: .subagent,
                    displayName: "scroll_implementation",
                    command: "Inspect the scroll implementation and report risks"
                )
            ),
            CodexSessionLogEvent(
                kind: .backgroundActivityFinished,
                detail: "Finished sub-agent",
                backgroundActivity: CodexSessionBackgroundActivity(
                    activityID: "/root/scroll_implementation",
                    kind: .subagent
                )
            ),
        ])
    }

    func testWatcherDropsEncryptedCollaborationSpawnMessage() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-13T20:10:14.011Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","namespace":"collaboration","arguments":"{\"task_name\":\"native_nav_sort\",\"fork_turns\":\"all\",\"message\":\"gAAAAABqVUYlTXM2t_RUiRJdyhJC7EScV_pvZf4oTf1czpLtlOnI53DmSgBobosvD5Be9dNM6WH5zQ6yMDpeYZ2vCxX3NxFWC6mgu-Y0O8lYQO-AQStZWi7216SJYD53GT4jg_KMQxU1ILOdm0eHXkSjWTy\"}","call_id":"call_spawn"}}
                {"timestamp":"2026-07-13T20:10:14.636Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_spawn","occurred_at_ms":1783973414635,"agent_thread_id":"thread-1","agent_path":"/root/native_nav_sort","kind":"started"}}
                """#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .backgroundActivityStarted,
                detail: "Started native_nav_sort",
                backgroundActivity: CodexSessionBackgroundActivity(
                    activityID: "/root/native_nav_sort",
                    hookActivityID: "thread-1",
                    spawnToolUseID: "call_spawn",
                    kind: .subagent,
                    displayName: "native_nav_sort"
                )
            ),
        ])
    }

    func testWatcherTreatsCurrentCollaborationInterruptAsFinish() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-12T18:44:11.355Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_spawn","occurred_at_ms":1783881851355,"agent_path":"/root/reviewer","kind":"started"}}
                {"timestamp":"2026-07-12T18:45:11.355Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_interrupt","occurred_at_ms":1783881911355,"agent_path":"/root/reviewer","kind":"interrupted"}}
                """#,
            expectedCount: 2
        )

        XCTAssertEqual(events.map(\.kind), [
            .backgroundActivityStarted,
            .backgroundActivityFinished,
        ])
        XCTAssertEqual(
            events.compactMap(\.backgroundActivity?.activityID),
            ["/root/reviewer", "/root/reviewer"]
        )
    }

    func testWatcherUsesCollaborationOccurrenceTimeForReplayCutoff() async throws {
        let cutoff = Date(timeIntervalSince1970: 1_783_881_800)
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-12T18:44:11.355Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_stale","occurred_at_ms":1783875653886,"agent_path":"/root/stale","kind":"started"}}
                {"timestamp":"2026-07-12T18:44:12.355Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_fresh","occurred_at_ms":1783881851355,"agent_path":"/root/fresh","kind":"started"}}
                """#,
            expectedCount: 1,
            multiAgentEventCutoff: cutoff
        )

        XCTAssertEqual(
            events.compactMap(\.backgroundActivity?.activityID),
            ["/root/fresh"]
        )
    }

    func testWatcherRestartsCompletedCollaborationAgentForFollowUpTask() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-12T17:06:52.466Z","type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_spawn","occurred_at_ms":1783876012466,"agent_path":"/root/plan_review","kind":"started"}}
                {"timestamp":"2026-07-12T17:09:47.604Z","type":"response_item","payload":{"type":"agent_message","author":"/root/plan_review","recipient":"/root","content":[{"type":"input_text","text":"Message Type: FINAL_ANSWER\nTask name: /root"}]}}
                {"timestamp":"2026-07-12T17:15:38.831Z","type":"response_item","payload":{"type":"agent_message","author":"/root","recipient":"/root/plan_review","content":[{"type":"input_text","text":"Message Type: NEW_TASK\nTask name: /root/plan_review"}]}}
                {"timestamp":"2026-07-12T17:16:14.745Z","type":"response_item","payload":{"type":"agent_message","author":"/root/plan_review","recipient":"/root","content":[{"type":"input_text","text":"Message Type: FINAL_ANSWER\nTask name: /root"}]}}
                """#,
            expectedCount: 4
        )

        XCTAssertEqual(events.map(\.kind), [
            .backgroundActivityStarted,
            .backgroundActivityFinished,
            .backgroundActivityStarted,
            .backgroundActivityFinished,
        ])
        XCTAssertEqual(
            events.compactMap(\.backgroundActivity?.activityID),
            Array(repeating: "/root/plan_review", count: 4)
        )
    }

    func testWatcherRejectsUndatedCollaborationEventsWhenCutoffIsActive() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"type":"event_msg","payload":{"type":"sub_agent_activity","event_id":"call_stale","agent_path":"/root/stale","kind":"started"}}
                {"type":"response_item","payload":{"type":"agent_message","author":"/root/current","recipient":"/root","content":[{"type":"input_text","text":"Message Type: FINAL_ANSWER\nTask name: /root"}]}}
                """#,
            expectedCount: 0,
            multiAgentEventCutoff: Date()
        )

        XCTAssertEqual(events, [])
    }

    func testWatcherRejectsCollaborationMessagesOutsideDirectParentRoute() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-12T17:15:38.831Z","type":"response_item","payload":{"type":"agent_message","author":"/root","recipient":"/root/reviewer/nested","content":[{"type":"input_text","text":"Message Type: NEW_TASK\nTask name: /root/reviewer/nested"}]}}
                {"timestamp":"2026-07-12T17:16:14.745Z","type":"response_item","payload":{"type":"agent_message","author":"/root/reviewer","recipient":"/other","content":[{"type":"input_text","text":"Message Type: FINAL_ANSWER\nTask name: /other"}]}}
                """#,
            expectedCount: 0
        )

        XCTAssertEqual(events, [])
    }

    func testWatcherParsesMultiAgentFixtureAsSubagentActivities() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp": "2026-07-09T05:41:47.374Z", "type": "response_item", "payload": {"type": "function_call", "id": "fc_01adacd050d2bed9016a4f349b59c88195b2dc9e9fb19e352d", "name": "spawn_agent", "namespace": "multi_agent_v1", "arguments": "{\"agent_type\":\"default\",\"message\":\"Reply with exactly the single word: done\"}", "call_id": "call_xKGDxu7LPYxEiAiAWXwGYJVl", "internal_chat_message_metadata_passthrough": {"turn_id": "019f4565-6618-7c53-a502-46cfe18ef04e"}}}
                {"timestamp": "2026-07-09T05:41:47.397Z", "type": "response_item", "payload": {"type": "function_call", "id": "fc_01adacd050d2bed9016a4f349b59e0819584d369de5229f896", "name": "spawn_agent", "namespace": "multi_agent_v1", "arguments": "{\"agent_type\":\"default\",\"message\":\"Reply with exactly the single word: done\"}", "call_id": "call_JkGuvNP9Ih7rl4tZEqtd1yxu", "internal_chat_message_metadata_passthrough": {"turn_id": "019f4565-6618-7c53-a502-46cfe18ef04e"}}}
                {"timestamp": "2026-07-09T05:41:47.881Z", "type": "response_item", "payload": {"type": "function_call_output", "call_id": "call_xKGDxu7LPYxEiAiAWXwGYJVl", "output": "{\"agent_id\":\"019f4565-7efd-7393-aefc-a600f5e0724e\",\"nickname\":\"Herschel\"}", "internal_chat_message_metadata_passthrough": {"turn_id": "019f4565-6618-7c53-a502-46cfe18ef04e"}}}
                {"timestamp": "2026-07-09T05:41:48.340Z", "type": "response_item", "payload": {"type": "function_call_output", "call_id": "call_JkGuvNP9Ih7rl4tZEqtd1yxu", "output": "{\"agent_id\":\"019f4565-80fa-7c03-915a-9e48e5b869a9\",\"nickname\":\"Halley\"}", "internal_chat_message_metadata_passthrough": {"turn_id": "019f4565-6618-7c53-a502-46cfe18ef04e"}}}
                {"timestamp": "2026-07-09T05:41:50.780Z", "type": "response_item", "payload": {"type": "function_call", "id": "fc_01adacd050d2bed9016a4f349df3f88195afce3bb18c7ad3c0", "name": "wait_agent", "namespace": "multi_agent_v1", "arguments": "{\"targets\":[\"019f4565-7efd-7393-aefc-a600f5e0724e\",\"019f4565-80fa-7c03-915a-9e48e5b869a9\"],\"timeout_ms\":60000}", "call_id": "call_d9kje1jqhIHq9DsE4zg6Dy3d", "internal_chat_message_metadata_passthrough": {"turn_id": "019f4565-6618-7c53-a502-46cfe18ef04e"}}}
                {"timestamp": "2026-07-09T05:41:51.209Z", "type": "response_item", "payload": {"type": "function_call_output", "call_id": "call_d9kje1jqhIHq9DsE4zg6Dy3d", "output": "{\"status\":{\"019f4565-7efd-7393-aefc-a600f5e0724e\":{\"completed\":\"done\"}},\"timed_out\":false}", "internal_chat_message_metadata_passthrough": {"turn_id": "019f4565-6618-7c53-a502-46cfe18ef04e"}}}
                {"timestamp": "2026-07-09T05:41:53.216Z", "type": "response_item", "payload": {"type": "function_call", "id": "fc_01adacd050d2bed9016a4f34a0ca7c819589f4994647c114cc", "name": "wait_agent", "namespace": "multi_agent_v1", "arguments": "{\"targets\":[\"019f4565-80fa-7c03-915a-9e48e5b869a9\"],\"timeout_ms\":60000}", "call_id": "call_8crieQN3luM8YuC2fp6sqAo4", "internal_chat_message_metadata_passthrough": {"turn_id": "019f4565-6618-7c53-a502-46cfe18ef04e"}}}
                {"timestamp": "2026-07-09T05:41:53.230Z", "type": "response_item", "payload": {"type": "function_call_output", "call_id": "call_8crieQN3luM8YuC2fp6sqAo4", "output": "{\"status\":{\"019f4565-80fa-7c03-915a-9e48e5b869a9\":{\"completed\":\"done\"}},\"timed_out\":false}", "internal_chat_message_metadata_passthrough": {"turn_id": "019f4565-6618-7c53-a502-46cfe18ef04e"}}}
                """#,
            expectedCount: 4
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .backgroundActivityStarted,
                detail: "Started Herschel",
                backgroundActivity: CodexSessionBackgroundActivity(
                    activityID: "019f4565-7efd-7393-aefc-a600f5e0724e",
                    hookActivityID: "019f4565-7efd-7393-aefc-a600f5e0724e",
                    spawnToolUseID: "call_xKGDxu7LPYxEiAiAWXwGYJVl",
                    kind: .subagent,
                    displayName: "Herschel",
                    command: "Reply with exactly the single word: done"
                )
            ),
            CodexSessionLogEvent(
                kind: .backgroundActivityStarted,
                detail: "Started Halley",
                backgroundActivity: CodexSessionBackgroundActivity(
                    activityID: "019f4565-80fa-7c03-915a-9e48e5b869a9",
                    hookActivityID: "019f4565-80fa-7c03-915a-9e48e5b869a9",
                    spawnToolUseID: "call_JkGuvNP9Ih7rl4tZEqtd1yxu",
                    kind: .subagent,
                    displayName: "Halley",
                    command: "Reply with exactly the single word: done"
                )
            ),
            CodexSessionLogEvent(
                kind: .backgroundActivityFinished,
                detail: "Finished sub-agent",
                backgroundActivity: CodexSessionBackgroundActivity(
                    activityID: "019f4565-7efd-7393-aefc-a600f5e0724e",
                    kind: .subagent
                )
            ),
            CodexSessionLogEvent(
                kind: .backgroundActivityFinished,
                detail: "Finished sub-agent",
                backgroundActivity: CodexSessionBackgroundActivity(
                    activityID: "019f4565-80fa-7c03-915a-9e48e5b869a9",
                    kind: .subagent
                )
            ),
        ])
    }

    func testWatcherIgnoresUnknownMultiAgentOutputCallID() async throws {
        let events = try await recordEvents(
            from: #"""
                {"timestamp":"2026-07-09T05:41:47.881Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_missing","output":"{\"agent_id\":\"agent-1\",\"nickname\":\"Herschel\"}"}}
                """#,
            expectedCount: 0
        )

        XCTAssertEqual(events, [])
    }

    func testWatcherDoesNotFinishTimedOutMultiAgentWaitWithoutTerminalStatus() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-09T05:41:50.780Z","type":"response_item","payload":{"type":"function_call","name":"wait_agent","namespace":"multi_agent_v1","arguments":"{\"targets\":[\"agent-1\"],\"timeout_ms\":1}","call_id":"call_wait"}}
                {"timestamp":"2026-07-09T05:41:51.209Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_wait","output":"{\"status\":{\"agent-1\":{\"pending\":\"still running\"}},\"timed_out\":true}"}}
                """#,
            expectedCount: 0
        )

        XCTAssertEqual(events, [])
    }

    func testWatcherParsesMultiAgentNamePrefixWhenNamespaceIsAbsent() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-09T05:41:47.374Z","type":"response_item","payload":{"type":"function_call","name":"multi_agent_v1.spawn_agent","arguments":"{\"agent_type\":\"reviewer\",\"message\":\"Inspect the diff\"}","call_id":"call_spawn"}}
                {"timestamp":"2026-07-09T05:41:47.881Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_spawn","output":"{\"agent_id\":\"agent-1\"}"}}
                """#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .backgroundActivityStarted,
                detail: "Started reviewer",
                backgroundActivity: CodexSessionBackgroundActivity(
                    activityID: "agent-1",
                    hookActivityID: "agent-1",
                    spawnToolUseID: "call_spawn",
                    kind: .subagent,
                    displayName: "reviewer",
                    command: "Inspect the diff"
                )
            ),
        ])
    }

    func testWatcherParsesRawSpawnAgentWhenNamespaceIsAbsent() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-09T05:41:47.374Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","arguments":"{\"agent_type\":\"reviewer\"}","call_id":"call_spawn"}}
                {"timestamp":"2026-07-09T05:41:47.881Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_spawn","output":"{\"agent_id\":\"agent-1\"}"}}
                """#,
            expectedCount: 1
        )

        XCTAssertEqual(events.first?.backgroundActivity?.activityID, "agent-1")
    }

    func testWatcherRejectsRawSpawnAgentFromUnknownNamespace() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-09T05:41:47.374Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","namespace":"other","arguments":"{\"agent_type\":\"reviewer\"}","call_id":"call_spawn"}}
                {"timestamp":"2026-07-09T05:41:47.881Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_spawn","output":"{\"agent_id\":\"agent-1\"}"}}
                """#,
            expectedCount: 0
        )

        XCTAssertEqual(events, [])
    }

    func testWatcherTreatsCloseAgentOutputAsFinish() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-09T05:41:53.216Z","type":"response_item","payload":{"type":"function_call","name":"close_agent","namespace":"multi_agent_v1","arguments":"{\"agent_id\":\"agent-1\"}","call_id":"call_close"}}
                {"timestamp":"2026-07-09T05:41:53.230Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_close","output":"{\"agent_id\":\"agent-1\"}"}}
                """#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .backgroundActivityFinished,
                detail: "Finished sub-agent",
                backgroundActivity: CodexSessionBackgroundActivity(
                    activityID: "agent-1",
                    kind: .subagent
                )
            ),
        ])
    }

    func testWatcherFallsBackToCloseAgentArgumentsWhenOutputHasNoAgentID() async throws {
        let events = try await recordEvents(
            from:
                #"""
                {"timestamp":"2026-07-09T05:41:53.216Z","type":"response_item","payload":{"type":"function_call","name":"close_agent","namespace":"multi_agent_v1","arguments":"{\"agent_id\":\"agent-1\"}","call_id":"call_close"}}
                {"timestamp":"2026-07-09T05:41:53.230Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_close","output":"{\"ok\":true}"}}
                """#,
            expectedCount: 1
        )

        XCTAssertEqual(events, [
            CodexSessionLogEvent(
                kind: .backgroundActivityFinished,
                detail: "Finished sub-agent",
                backgroundActivity: CodexSessionBackgroundActivity(
                    activityID: "agent-1",
                    kind: .subagent
                )
            ),
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
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        multiAgentEventCutoff: Date? = nil
    ) async throws -> [CodexSessionLogEvent] {
        let logURL = try makeLogURL()
        let recorder = EventRecorder()
        let eventsExpectation = expectedCount > 0
            ? expectation(description: "Expected watcher events arrive")
            : nil
        eventsExpectation?.expectedFulfillmentCount = expectedCount
        eventsExpectation?.assertForOverFulfill = true

        let watcher = CodexSessionLogWatcher(
            logURL: logURL,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
            multiAgentEventCutoff: multiAgentEventCutoff
        ) { event in
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
