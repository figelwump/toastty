import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct AgentHookDispatcherTests {
    private static let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let panelID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
    // 2026-08-06T20:15:30.125Z; the fraction is exactly representable in
    // binary so millisecond formatting is deterministic.
    private static let timestamp = Date(timeIntervalSince1970: 1_786_047_330.125)

    private static func makeEvent(
        kind: AgentHookEventKind,
        sessionID: String = "sess-hook",
        cwd: String? = "/repo",
        previousStatus: SessionStatusKind? = nil,
        newStatus: SessionStatusKind? = nil,
        launchReason: AgentHookLaunchReason? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            kind: kind,
            timestamp: timestamp,
            sessionID: sessionID,
            agent: .codex,
            workspaceID: workspaceID,
            panelID: panelID,
            cwd: cwd,
            previousStatus: previousStatus,
            newStatus: newStatus,
            launchReason: launchReason
        )
    }

    private static func makeDispatcher(
        runner: any AgentHookProcessRunning,
        scriptPath: String?,
        socketPath: String = "/tmp/toastty-test-socket.sock",
        cliExecutablePath: String? = "/tmp/toastty-test-cli",
        maximumConcurrentProcesses: Int = AgentHookDispatcher.defaultMaximumConcurrentProcesses
    ) -> AgentHookDispatcher {
        AgentHookDispatcher(
            socketPath: socketPath,
            cliExecutablePath: cliExecutablePath,
            scriptPath: scriptPath,
            runner: runner,
            maximumConcurrentProcesses: maximumConcurrentProcesses
        )
    }

    // MARK: - Golden JSON

    @Test
    func turnCompleteEventEncodesGoldenSchemaV1JSON() throws {
        let event = Self.makeEvent(
            kind: .turnComplete,
            previousStatus: .working,
            newStatus: .ready
        )

        let json = try #require(String(data: event.jsonData(), encoding: .utf8))

        #expect(json == """
        {"agent":"codex","cwd":"/repo","event":"turn-complete","launchReason":null,\
        "newStatus":"ready","panelID":"66666666-7777-8888-9999-AAAAAAAAAAAA",\
        "previousStatus":"working","schemaVersion":1,"sessionID":"sess-hook",\
        "timestamp":"2026-08-06T20:15:30.125Z",\
        "workspaceID":"11111111-2222-3333-4444-555555555555"}
        """)
    }

    @Test
    func sessionStartEventEncodesLaunchReasonAndNullStatuses() throws {
        let event = Self.makeEvent(kind: .sessionStart, cwd: nil, launchReason: .restore)

        let payload = try JSONSerialization.jsonObject(with: event.jsonData()) as? [String: Any]
        let json = try #require(payload)

        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["event"] as? String == "session-start")
        #expect(json["launchReason"] as? String == "restore")
        #expect(json["cwd"] is NSNull)
        #expect(json["previousStatus"] is NSNull)
        #expect(json["newStatus"] is NSNull)
        #expect(json["timestamp"] as? String == "2026-08-06T20:15:30.125Z")
    }

    @Test
    func everyEventKindEncodesItsPublicName() throws {
        let expectedNames: [AgentHookEventKind: String] = [
            .sessionStart: "session-start",
            .turnComplete: "turn-complete",
            .needsApproval: "needs-approval",
            .sessionError: "session-error",
            .sessionStop: "session-stop",
        ]

        for kind in AgentHookEventKind.allCases {
            let payload = try JSONSerialization.jsonObject(
                with: Self.makeEvent(kind: kind).jsonData()
            ) as? [String: Any]
            let json = try #require(payload)
            #expect(json["event"] as? String == expectedNames[kind])
        }
    }

    // MARK: - Environment contract

    @Test
    func environmentOverlayCarriesFullDocumentedContract() {
        let dispatcher = Self.makeDispatcher(
            runner: ControlledHookRunner(),
            scriptPath: "/tmp/hook.sh",
            socketPath: "/tmp/injected.sock",
            cliExecutablePath: "/tmp/injected-cli"
        )
        let event = Self.makeEvent(
            kind: .sessionStart,
            previousStatus: nil,
            newStatus: nil,
            launchReason: .processWatch
        )

        let overlay = dispatcher.environmentOverlay(for: event)

        #expect(overlay == [
            "TOASTTY_HOOK_SCHEMA_VERSION": "1",
            "TOASTTY_HOOK_EVENT": "session-start",
            "TOASTTY_AGENT": "codex",
            "TOASTTY_SESSION_ID": "sess-hook",
            "TOASTTY_WORKSPACE_ID": "11111111-2222-3333-4444-555555555555",
            "TOASTTY_PANEL_ID": "66666666-7777-8888-9999-AAAAAAAAAAAA",
            "TOASTTY_SESSION_CWD": "/repo",
            "TOASTTY_CLI_PATH": "/tmp/injected-cli",
            "TOASTTY_SOCKET_PATH": "/tmp/injected.sock",
            "TOASTTY_LAUNCH_REASON": "process-watch",
        ])
    }

    @Test
    func environmentOverlayUsesEmptyStringsForAbsentOptionals() {
        let dispatcher = Self.makeDispatcher(
            runner: ControlledHookRunner(),
            scriptPath: "/tmp/hook.sh",
            cliExecutablePath: nil
        )
        let event = Self.makeEvent(kind: .sessionStop, cwd: nil)

        let overlay = dispatcher.environmentOverlay(for: event)

        #expect(overlay["TOASTTY_SESSION_CWD"] == "")
        #expect(overlay["TOASTTY_CLI_PATH"] == "")
        #expect(overlay["TOASTTY_LAUNCH_REASON"] == "")
    }

    // MARK: - Path handling

    @Test
    func nilScriptPathDisablesEnqueueEntirely() async {
        let runner = ControlledHookRunner()
        let dispatcher = Self.makeDispatcher(runner: runner, scriptPath: nil)

        dispatcher.enqueue(Self.makeEvent(kind: .sessionStart))
        dispatcher.enqueue(Self.makeEvent(kind: .turnComplete))
        await settleNotificationTasks()

        #expect(dispatcher.isEnabled == false)
        #expect(dispatcher.queuedSessionIDsForTesting.isEmpty)
        #expect(await runner.requestCount() == 0)
    }

    @Test
    func missingScriptPathSkipsExecutionWithoutInvokingRunner() async {
        let runner = ControlledHookRunner()
        let dispatcher = Self.makeDispatcher(
            runner: runner,
            scriptPath: "/nonexistent/toastty-hook-\(UUID().uuidString)"
        )

        dispatcher.enqueue(Self.makeEvent(kind: .sessionStart))
        await SessionRuntimeStoreTestSupport.waitUntil {
            dispatcher.queuedSessionIDsForTesting.isEmpty
        }

        #expect(await runner.requestCount() == 0)
    }

    @Test
    func nonExecutableScriptPathSkipsExecutionWithoutInvokingRunner() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: scriptURL.path
        )
        let runner = ControlledHookRunner()
        let dispatcher = Self.makeDispatcher(runner: runner, scriptPath: scriptURL.path)

        dispatcher.enqueue(Self.makeEvent(kind: .turnComplete))
        await SessionRuntimeStoreTestSupport.waitUntil {
            dispatcher.queuedSessionIDsForTesting.isEmpty
        }

        #expect(await runner.requestCount() == 0)
    }

    @Test
    func configuredScriptPathIssueDescribesMissingAndNonExecutablePaths() throws {
        #expect(AgentHookDispatcher.configuredScriptPathIssue(nil) == nil)

        let missingPath = "/nonexistent/toastty-hook-\(UUID().uuidString)"
        #expect(
            AgentHookDispatcher.configuredScriptPathIssue(missingPath) ==
                "Agent hook script does not exist: \(missingPath)"
        )

        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        #expect(AgentHookDispatcher.configuredScriptPathIssue(scriptURL.path) == nil)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: scriptURL.path
        )
        #expect(
            AgentHookDispatcher.configuredScriptPathIssue(scriptURL.path) ==
                "Agent hook script is not executable: \(scriptURL.path)"
        )

        #expect(
            AgentHookDispatcher.configuredScriptPathIssue(
                scriptURL.deletingLastPathComponent().path
            ) ==
                "Agent hook script is not a regular file: \(scriptURL.deletingLastPathComponent().path)"
        )
    }

    // MARK: - Ordering and concurrency

    @Test
    func sameSessionInvocationsRunStrictlyInOrder() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let runner = ControlledHookRunner()
        let dispatcher = Self.makeDispatcher(runner: runner, scriptPath: scriptURL.path)

        dispatcher.enqueue(Self.makeEvent(kind: .sessionStart, launchReason: .managed))
        dispatcher.enqueue(Self.makeEvent(kind: .needsApproval, newStatus: .needsApproval))
        dispatcher.enqueue(Self.makeEvent(kind: .turnComplete, newStatus: .ready))
        dispatcher.enqueue(Self.makeEvent(kind: .sessionStop))
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 4)

        let names = try AgentHookTestSupport.recordedEventNames(await runner.requests)
        #expect(names == ["session-start", "needs-approval", "turn-complete", "session-stop"])
        #expect(dispatcher.queuedSessionIDsForTesting.isEmpty)
    }

    @Test
    func crossSessionExecutionNeverExceedsFourConcurrentProcesses() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let runner = ControlledHookRunner(gated: ())
        let dispatcher = Self.makeDispatcher(runner: runner, scriptPath: scriptURL.path)

        for index in 0..<6 {
            dispatcher.enqueue(Self.makeEvent(kind: .sessionStart, sessionID: "sess-\(index)"))
        }
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 4)

        // Two sessions must remain blocked on the global process limit.
        #expect(await runner.requestCount() == 4)
        #expect(dispatcher.peakConcurrentProcessCountForTesting == 4)

        await runner.releaseAll(count: 6)
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 6)

        #expect(await runner.requestCount() == 6)
        #expect(await runner.peakConcurrentRunCount <= 4)
        await SessionRuntimeStoreTestSupport.waitUntil {
            dispatcher.queuedSessionIDsForTesting.isEmpty
        }
        #expect(dispatcher.queuedSessionIDsForTesting.isEmpty)
    }

    // MARK: - Queue caps

    @Test
    func fullQueueDropsNewestStatusEventAndKeepsStopEnqueueable() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let runner = ControlledHookRunner(gated: ())
        let dispatcher = Self.makeDispatcher(runner: runner, scriptPath: scriptURL.path)

        // First event starts running and gates; the next 8 fill the queue.
        dispatcher.enqueue(Self.makeEvent(kind: .sessionStart))
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 1)
        for index in 0..<8 {
            dispatcher.enqueue(Self.makeEvent(
                kind: .turnComplete,
                cwd: "/status-\(index)",
                newStatus: .ready
            ))
        }
        #expect(dispatcher.queuedEventCountForTesting(sessionID: "sess-hook") == 8)

        // A ninth status event is the newest and is dropped.
        dispatcher.enqueue(Self.makeEvent(kind: .needsApproval, cwd: "/status-dropped"))
        #expect(dispatcher.queuedEventCountForTesting(sessionID: "sess-hook") == 8)

        // Stop evicts the oldest queued status event instead of being dropped.
        dispatcher.enqueue(Self.makeEvent(kind: .sessionStop))
        #expect(dispatcher.queuedEventCountForTesting(sessionID: "sess-hook") == 8)

        await runner.releaseAll(count: 9)
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 9)

        let requests = await runner.requests
        let names = try AgentHookTestSupport.recordedEventNames(requests)
        #expect(names == [
            "session-start",
            "turn-complete", "turn-complete", "turn-complete", "turn-complete",
            "turn-complete", "turn-complete", "turn-complete",
            "session-stop",
        ])
        // The evicted event was the oldest queued status (/status-0) and the
        // dropped one was the newest (needs-approval).
        let cwds = try requests.map { request in
            try AgentHookTestSupport.decodeHookPayload(request)["cwd"] as? String
        }
        #expect(cwds.contains("/status-0") == false)
        #expect(cwds.contains("/status-dropped") == false)
        #expect(cwds.contains("/status-1"))
        await SessionRuntimeStoreTestSupport.waitUntil {
            dispatcher.queuedSessionIDsForTesting.isEmpty
        }
        #expect(dispatcher.queuedSessionIDsForTesting.isEmpty)
    }

    @Test
    func lifecycleOnlyFloodRemainsBoundedAndPreservesNewestStop() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let runner = ControlledHookRunner(gated: ())
        let dispatcher = Self.makeDispatcher(runner: runner, scriptPath: scriptURL.path)

        dispatcher.enqueue(Self.makeEvent(kind: .sessionStart))
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 1)
        for _ in 0..<4 {
            dispatcher.enqueue(Self.makeEvent(kind: .sessionStop))
            dispatcher.enqueue(Self.makeEvent(kind: .sessionStart, launchReason: .managed))
        }
        #expect(dispatcher.queuedEventCountForTesting(sessionID: "sess-hook") == 8)

        // There is no status event to evict. The oldest queued lifecycle event
        // is discarded so the newest stop is retained without exceeding eight.
        dispatcher.enqueue(Self.makeEvent(kind: .sessionStop))
        #expect(dispatcher.queuedEventCountForTesting(sessionID: "sess-hook") == 8)

        await runner.releaseAll(count: 9)
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 9)
        let names = try AgentHookTestSupport.recordedEventNames(await runner.requests)
        #expect(names.count == 9)
        #expect(names.last == "session-stop")
    }

    @Test
    func eventWaitingForGlobalSlotStillCountsTowardSessionQueueLimit() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let runner = ControlledHookRunner(gated: ())
        let dispatcher = Self.makeDispatcher(
            runner: runner,
            scriptPath: scriptURL.path,
            maximumConcurrentProcesses: 1
        )

        dispatcher.enqueue(Self.makeEvent(kind: .sessionStart, sessionID: "slot-owner"))
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 1)
        dispatcher.enqueue(Self.makeEvent(kind: .sessionStart, sessionID: "slot-waiter"))
        await settleNotificationTasks()

        // The waiter's first event remains in the bounded queue until a global
        // process slot is available; it must not disappear into a hidden waiter.
        #expect(dispatcher.queuedEventCountForTesting(sessionID: "slot-waiter") == 1)
        for index in 0..<7 {
            dispatcher.enqueue(Self.makeEvent(
                kind: .turnComplete,
                sessionID: "slot-waiter",
                cwd: "/queued-\(index)",
                newStatus: .ready
            ))
        }
        dispatcher.enqueue(Self.makeEvent(
            kind: .sessionError,
            sessionID: "slot-waiter",
            cwd: "/dropped",
            newStatus: .error
        ))
        #expect(dispatcher.queuedEventCountForTesting(sessionID: "slot-waiter") == 8)

        await runner.releaseOne()
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 2)
        await runner.releaseAll(count: 8)
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 9)
        let requests = await runner.requests
        let cwds = try requests.map {
            try AgentHookTestSupport.decodeHookPayload($0)["cwd"] as? String
        }
        #expect(cwds.contains("/dropped") == false)
    }

    @Test
    func statusEventsAfterStopAreDroppedUntilNextSessionStart() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let runner = ControlledHookRunner(gated: ())
        let dispatcher = Self.makeDispatcher(runner: runner, scriptPath: scriptURL.path)

        dispatcher.enqueue(Self.makeEvent(kind: .sessionStop))
        dispatcher.enqueue(Self.makeEvent(kind: .turnComplete))
        dispatcher.enqueue(Self.makeEvent(kind: .sessionStop))
        #expect(dispatcher.queuedEventCountForTesting(sessionID: "sess-hook") <= 1)
        dispatcher.enqueue(Self.makeEvent(kind: .sessionStart, launchReason: .managed))

        await runner.releaseAll(count: 2)
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 2)

        let names = try AgentHookTestSupport.recordedEventNames(await runner.requests)
        #expect(names == ["session-stop", "session-start"])
    }

    // MARK: - Config reload snapshots

    @Test
    func queuedEventsKeepTheirCapturedScriptPathAcrossReload() async throws {
        let firstScriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let secondScriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let runner = ControlledHookRunner(gated: ())
        let dispatcher = Self.makeDispatcher(runner: runner, scriptPath: firstScriptURL.path)

        dispatcher.enqueue(Self.makeEvent(kind: .sessionStart))
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 1)
        dispatcher.enqueue(Self.makeEvent(kind: .turnComplete, newStatus: .ready))

        // The queued event captured the original path at enqueue time.
        dispatcher.updateScriptPath(secondScriptURL.path)
        dispatcher.enqueue(Self.makeEvent(kind: .sessionError, newStatus: .error))

        await runner.releaseAll(count: 3)
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 3)

        let requests = await runner.requests
        #expect(requests.map(\.scriptPath) == [
            firstScriptURL.path,
            firstScriptURL.path,
            secondScriptURL.path,
        ])
    }

    @Test
    func disablingHookDrainsQueuedWorkButBlocksNewEnqueues() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let runner = ControlledHookRunner(gated: ())
        let dispatcher = Self.makeDispatcher(runner: runner, scriptPath: scriptURL.path)

        dispatcher.enqueue(Self.makeEvent(kind: .sessionStart))
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 1)
        dispatcher.enqueue(Self.makeEvent(kind: .turnComplete, newStatus: .ready))

        dispatcher.updateScriptPath(nil)
        dispatcher.enqueue(Self.makeEvent(kind: .sessionError, newStatus: .error))

        await runner.releaseAll(count: 2)
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 2)
        await SessionRuntimeStoreTestSupport.waitUntil {
            dispatcher.queuedSessionIDsForTesting.isEmpty
        }

        let names = try AgentHookTestSupport.recordedEventNames(await runner.requests)
        #expect(names == ["session-start", "turn-complete"])
        #expect(dispatcher.isEnabled == false)
    }

    // MARK: - Real process execution

    @Test
    func realProcessWritingMegabytesToBothStreamsCannotDeadlock() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript(contents: """
        #!/bin/sh
        cat > /dev/null
        dd if=/dev/zero bs=1048576 count=1 2>/dev/null
        dd if=/dev/zero bs=1048576 count=1 1>&2 2>/dev/null
        exit 0
        """)
        let runner = AgentHookLiveProcessRunner()

        let result = await runner.run(AgentHookInvocationRequest(
            scriptPath: scriptURL.path,
            stdinData: Data("{}".utf8),
            environmentOverlay: [:],
            executionTimeout: 20,
            terminationGracePeriod: 1
        ))

        #expect(result == .exited(code: 0))
    }

    @Test
    func realProcessNonzeroExitIsReported() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript(contents: """
        #!/bin/sh
        cat > /dev/null
        exit 3
        """)
        let runner = AgentHookLiveProcessRunner()

        let result = await runner.run(AgentHookInvocationRequest(
            scriptPath: scriptURL.path,
            stdinData: Data("{}".utf8),
            environmentOverlay: [:],
            executionTimeout: 20,
            terminationGracePeriod: 1
        ))

        #expect(result == .exited(code: 3))
    }

    @Test
    func realProcessExitingBeforeReadingStdinReportsWriteFailureNotCrash() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript(contents: """
        #!/bin/sh
        exec <&-
        exit 0
        """)
        let runner = AgentHookLiveProcessRunner()

        // A large payload forces the pipe write to outlive the process for at
        // least some runs; either outcome must be an orderly exit(0) result.
        let result = await runner.run(AgentHookInvocationRequest(
            scriptPath: scriptURL.path,
            stdinData: Data(repeating: 0x7B, count: 1_048_576),
            environmentOverlay: [:],
            executionTimeout: 20,
            terminationGracePeriod: 1
        ))

        #expect(result.completion == .exited(code: 0))
    }

    @Test
    func realProcessHonoringSIGTERMReportsTimeoutWithoutForceKill() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript(contents: """
        #!/bin/sh
        cat > /dev/null
        sleep 30
        """)
        let runner = AgentHookLiveProcessRunner()

        let result = await runner.run(AgentHookInvocationRequest(
            scriptPath: scriptURL.path,
            stdinData: Data("{}".utf8),
            environmentOverlay: [:],
            executionTimeout: 0.3,
            terminationGracePeriod: 2
        ))

        #expect(result.completion == .timedOut(didForceKill: false))
    }

    @Test
    func realProcessIgnoringSIGTERMIsEscalatedToSIGKILL() async throws {
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript(contents: """
        #!/bin/sh
        trap "" TERM
        cat > /dev/null
        sleep 30
        """)
        let runner = AgentHookLiveProcessRunner()

        let result = await runner.run(AgentHookInvocationRequest(
            scriptPath: scriptURL.path,
            stdinData: Data("{}".utf8),
            environmentOverlay: [:],
            executionTimeout: 0.3,
            terminationGracePeriod: 0.3
        ))

        #expect(result.completion == .timedOut(didForceKill: true))
    }

    @Test
    func realProcessReceivesPayloadAndEnvironmentOverlay() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-hook-output-\(UUID().uuidString)", isDirectory: false)
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript(contents: """
        #!/bin/sh
        printf '%s\\n' "$TOASTTY_HOOK_EVENT" > "\(outputURL.path)"
        printf '%s\\n' "$TOASTTY_SOCKET_PATH" >> "\(outputURL.path)"
        cat >> "\(outputURL.path)"
        exit 0
        """)
        let runner = AgentHookLiveProcessRunner()

        let result = await runner.run(AgentHookInvocationRequest(
            scriptPath: scriptURL.path,
            stdinData: Data("{\"event\":\"turn-complete\"}".utf8),
            environmentOverlay: [
                "TOASTTY_HOOK_EVENT": "turn-complete",
                "TOASTTY_SOCKET_PATH": "/tmp/injected.sock",
            ],
            executionTimeout: 20,
            terminationGracePeriod: 1
        ))

        #expect(result == .exited(code: 0))
        let output = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(output == "turn-complete\n/tmp/injected.sock\n{\"event\":\"turn-complete\"}")
    }
}
