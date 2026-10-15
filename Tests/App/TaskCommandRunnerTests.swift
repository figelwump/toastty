import Foundation
import Testing
@testable import ToasttyApp

/// Runs real processes: the runner's job is process-group and pipe
/// handling, which a fake cannot check.
struct TaskCommandRunnerTests {
    private func shell(_ script: String, stdin: Data? = nil, timeout: TimeInterval = 10, directory: String = "/tmp") -> TaskCommand {
        TaskCommand(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            directory: directory,
            environment: ["PATH": "/usr/bin:/bin", "TASK_VALUE": "from-env"],
            standardInput: stdin,
            timeout: timeout
        )
    }

    @Test func capturesExitCodeOutputEnvironmentAndDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "task-runner-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await TaskLiveCommandRunner().run(shell(
            #"pwd -P; echo "$TASK_VALUE"; cat; echo oops >&2; exit 3"#,
            stdin: Data("typed input\n".utf8),
            directory: directory.path
        ))

        #expect(result.termination == .exited(3))
        #expect(result.stdoutText == "\(directory.resolvingSymlinksInPath().path)\nfrom-env\ntyped input\n")
        #expect(result.stderrText == "oops\n")
    }

    @Test func timeoutStopsTheWholeProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "task-runner-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: marker) }
        let started = Date()
        // The grandchild ignores nothing; SIGTERM to the group must reach it.
        let result = await TaskLiveCommandRunner(terminationGracePeriod: 1).run(shell(
            "sleep 30 & echo $! > \(marker.path); wait",
            timeout: 1
        ))

        #expect(result.termination == .timedOut)
        #expect(Date().timeIntervalSince(started) < 8)
        let grandchild = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Reaped or gone: kill(pid, 0) fails once the process no longer exists.
        try await waitUntil { kill(grandchild, 0) != 0 }
    }

    @Test func termResistantChildIsKilledAfterTheGracePeriod() async {
        let started = Date()
        let result = await TaskLiveCommandRunner(terminationGracePeriod: 0.5).run(shell(
            "trap '' TERM; sleep 30",
            timeout: 0.5
        ))
        #expect(result.termination == .timedOut)
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test func cancellationStopsTheCommand() async {
        let started = Date()
        let task = Task { await TaskLiveCommandRunner().run(shell("sleep 30")) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.value
        #expect(result.termination == .cancelled)
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test func largeOutputOnBothStreamsIsCappedWithoutStalling() async {
        let result = await TaskLiveCommandRunner(outputLimit: 1024).run(shell(
            "i=0; while [ $i -lt 2000 ]; do echo 0123456789abcdef0123456789abcdef; echo fedcba9876543210fedcba9876543210 >&2; i=$((i+1)); done; exit 0"
        ))
        #expect(result.termination == .exited(0))
        #expect(result.stdout.count == 1024)
        #expect(result.stderr.count == 1024)
    }

    @Test func aDescendantThatKeepsThePipesOpenDoesNotHoldTheResult() async {
        let started = Date()
        // The background job outlives the script and inherits stdout.
        let result = await TaskLiveCommandRunner(outputDrainGracePeriod: 0.5).run(shell(
            "(sleep 4 &); echo done"
        ))
        #expect(result.termination == .exited(0))
        #expect(result.stdoutText == "done\n")
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func stdinThatTheCommandNeverReadsDoesNotBlock() async {
        let result = await TaskLiveCommandRunner().run(shell(
            "exit 0",
            stdin: Data(repeating: 65, count: 1024 * 1024)
        ))
        #expect(result.termination == .exited(0))
    }

    @Test func missingExecutableOrDirectoryIsALaunchFailure() async {
        var command = shell("true")
        command.executablePath = "/nonexistent/tool"
        guard case .launchFailed = await TaskLiveCommandRunner().run(command).termination else {
            Issue.record("Expected a launch failure")
            return
        }
        guard case .launchFailed = await TaskLiveCommandRunner().run(shell("true", directory: "/nonexistent-dir")).termination else {
            Issue.record("Expected a launch failure for a missing directory")
            return
        }
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                Issue.record("Condition did not become true in time")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

struct TaskCommandEnvironmentTests {
    @Test func dropsToasttyVariablesAndSetsPathAndPromptGuards() {
        let environment = TaskCommandEnvironment.make(
            base: ["HOME": "/Users/me", "TOASTTY_SESSION_ID": "s", "TOASTTY_SOCKET_PATH": "/x", "PATH": "/usr/bin"],
            path: "/opt/homebrew/bin:/usr/bin",
            extra: ["TOASTTY_TASK_ID": "t"]
        )
        #expect(environment == [
            "HOME": "/Users/me",
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "GIT_TERMINAL_PROMPT": "0",
            "GH_PROMPT_DISABLED": "1",
            "TOASTTY_TASK_ID": "t",
        ])
    }
}
