import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

struct ToasttyCLITaskTests {
    @Test
    func taskCreateMapsFlagsToTheActionAndResolvesPaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-cli-task-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Fix it.\nThen test it.".write(to: directory.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
        let workspaceID = UUID()

        let invocation = try ToasttyCLI.parse(
            arguments: [
                "task", "create", "Composer keeps a blank line",
                "--file", "shot.png", "--file", "/abs/log.txt",
                "--workspace", workspaceID.uuidString,
                "--agent", "codex", "--model", "gpt-6.1-sol", "--effort", "high",
                "--prompt-file", "brief.md",
                "--title", "Composer blank line", "--slug", "composer-blank-line",
                "--request-id", "req-1",
            ],
            environment: ["PWD": directory.path]
        )

        guard case .appControlRun(let kind, let id, let args) = invocation.command else {
            Issue.record("expected an app-control run")
            return
        }
        #expect(kind == .action)
        #expect(id == "task.create")
        #expect(invocation.taskWait == nil)
        #expect(args == [
            "text": .string("Composer keeps a blank line"),
            "files": .array([.string(directory.appendingPathComponent("shot.png").path), .string("/abs/log.txt")]),
            "workspace": .string(workspaceID.uuidString),
            "agent": .string("codex"),
            "model": .string("gpt-6.1-sol"),
            "effort": .string("high"),
            "prompt": .string("Fix it.\nThen test it."),
            "title": .string("Composer blank line"),
            "slug": .string("composer-blank-line"),
            "clientRequestID": .string("req-1"),
        ])
    }

    @Test
    func startWorkMapsFlagsToItsActionAndCreateTakesStartWorkFlags() throws {
        let startWork = try ToasttyCLI.parse(
            arguments: ["task", "start-work", "--base", "feat/stack", "--branch-prefix", "fix", "--title", "Split it"],
            environment: [:]
        )
        #expect(startWork.command == .appControlRun(kind: .action, id: "task.start-work", args: [
            "base": .string("feat/stack"),
            "branchPrefix": .string("fix"),
            "title": .string("Split it"),
        ]))

        let create = try ToasttyCLI.parse(
            arguments: ["task", "create", "x", "--start-work", "--base", "main", "--branch-prefix", "feat"],
            environment: [:]
        )
        guard case .appControlRun(_, "task.create", let args) = create.command else {
            Issue.record("expected task.create")
            return
        }
        #expect(args["startWork"] == .bool(true))
        #expect(args["base"] == .string("main"))
        #expect(args["branchPrefix"] == .string("feat"))
        #expect(args["fork"] == nil)

        let fork = try ToasttyCLI.parse(arguments: ["task", "create", "x", "--fork", "--start-work"], environment: [:])
        guard case .appControlRun(_, "task.create", let forkArgs) = fork.command else {
            Issue.record("expected task.create")
            return
        }
        #expect(forkArgs["fork"] == .bool(true))
        #expect(forkArgs["startWork"] == .bool(true))
        // The fork starts after the caller's turn, which --wait would hold.
        #expect(throws: ToasttyCLIError.self) {
            try ToasttyCLI.parse(arguments: ["task", "create", "x", "--fork", "--wait"], environment: [:])
        }

        #expect(throws: ToasttyCLIError.self) {
            try ToasttyCLI.parse(arguments: ["task", "create", "x", "--base", "main"], environment: [:])
        }
        #expect(throws: ToasttyCLIError.self) {
            try ToasttyCLI.parse(arguments: ["task", "start-work", "now"], environment: [:])
        }
    }

    @Test
    func taskCreateWaitTakesATimeout() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["task", "create", "--text", "x", "--wait", "--timeout", "30"],
            environment: [:]
        )
        #expect(invocation.taskWait == CLITaskWait(timeout: 30))
        let defaulted = try ToasttyCLI.parse(arguments: ["task", "create", "x", "--wait"], environment: [:])
        #expect(defaulted.taskWait == CLITaskWait(timeout: CLITaskWait.defaultTimeout))
    }

    @Test(arguments: [
        ["task", "create", "a", "b"],
        ["task", "create", "a", "--text", "b"],
        ["task", "create", "a", "--prompt", "p", "--prompt-file", "f"],
        ["task", "create", "a", "--timeout", "5"],
        ["task", "create", "a", "--wait", "--timeout", "0"],
        ["task", "create", "a", "--workspace", "toastty"],
        ["task", "retry"],
        ["task", "get", "not-a-uuid"],
        ["task", "list", "extra"],
        ["task", "archive", "x"],
        ["task"],
    ])
    func taskUsageErrors(arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try ToasttyCLI.parse(arguments: arguments, environment: [:])
        }
    }

    @Test
    func taskVerbsMapToQueriesAndActions() throws {
        let taskID = UUID().uuidString
        let expected: [(arguments: [String], kind: AppControlCommandKind, id: String, args: [String: AutomationJSONValue])] = [
            (["task", "get", taskID], .query, "task.get", ["taskID": .string(taskID)]),
            (["task", "retry", taskID], .action, "task.retry", ["taskID": .string(taskID)]),
            (["task", "delete", taskID], .action, "task.delete", ["taskID": .string(taskID)]),
            (["task", "list"], .query, "task.list", [:]),
        ]
        for entry in expected {
            let invocation = try ToasttyCLI.parse(arguments: entry.arguments, environment: [:])
            guard case .appControlRun(let kind, let id, let args) = invocation.command else {
                Issue.record("expected an app-control run for \(entry.arguments)")
                continue
            }
            #expect(kind == entry.kind)
            #expect(id == entry.id)
            #expect(args == entry.args)
        }
    }

    @Test
    func taskSetWorkspaceTakesAnOpenOrARecentWorkspaceOrADirectory() throws {
        let taskID = UUID().uuidString
        let workspaceID = UUID().uuidString
        let open = try ToasttyCLI.parse(arguments: ["task", "set-workspace", taskID, "--workspace", workspaceID], environment: [:])
        #expect(open.command == .appControlRun(
            kind: .action,
            id: "task.set-workspace",
            args: ["taskID": .string(taskID), "workspace": .string(workspaceID)]
        ))
        let recent = try ToasttyCLI.parse(arguments: ["task", "set-workspace", taskID, "--recent", workspaceID], environment: [:])
        #expect(recent.command == .appControlRun(
            kind: .action,
            id: "task.set-workspace",
            args: ["taskID": .string(taskID), "recentWorkspace": .string(workspaceID)]
        ))
        let root = try ToasttyCLI.parse(arguments: ["task", "set-workspace", taskID, "--root", "~/repos/website"], environment: [:])
        #expect(root.command == .appControlRun(
            kind: .action,
            id: "task.set-workspace",
            args: ["taskID": .string(taskID), "rootDirectory": .string("~/repos/website")]
        ))
        let choices = try ToasttyCLI.parse(arguments: ["task", "workspace-choices"], environment: [:])
        #expect(choices.command == .appControlRun(kind: .query, id: "task.workspace-choices", args: [:]))
        let forTask = try ToasttyCLI.parse(arguments: ["task", "workspace-choices", taskID], environment: [:])
        #expect(forTask.command == .appControlRun(kind: .query, id: "task.workspace-choices", args: ["taskID": .string(taskID)]))

        for arguments in [
            ["task", "set-workspace", taskID],
            ["task", "set-workspace", taskID, "--workspace", workspaceID, "--recent", workspaceID],
            ["task", "set-workspace", taskID, "--workspace", workspaceID, "--root", "/tmp"],
            ["task", "set-workspace", taskID, "--workspace", "toastty"],
            ["task", "workspace-choices", "toastty"],
        ] {
            #expect(throws: ToasttyCLIError.self) {
                _ = try ToasttyCLI.parse(arguments: arguments, environment: [:])
            }
        }
    }

    @Test
    func sendWatchAndListMapToTheirCommands() throws {
        let taskID = UUID().uuidString
        let other = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-cli-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Rebase on main.\nThen push.".write(to: directory.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

        #expect(try ToasttyCLI.parse(arguments: ["task", "send", taskID, "status?"], environment: [:]).command
            == .appControlRun(kind: .action, id: "task.send", args: ["taskID": .string(taskID), "text": .string("status?")]))
        #expect(try ToasttyCLI.parse(arguments: ["task", "send", taskID, "--text-file", "note.md"], environment: ["PWD": directory.path]).command
            == .appControlRun(kind: .action, id: "task.send", args: ["taskID": .string(taskID), "text": .string("Rebase on main.\nThen push.")]))

        let notify = try ToasttyCLI.parse(arguments: ["task", "watch", taskID, "--until", "idle", "--notify", other], environment: [:])
        #expect(notify.command == .appControlRun(kind: .action, id: "task.watch", args: [
            "taskID": .string(taskID), "until": .string("idle"), "notifyTaskID": .string(other),
        ]))
        #expect(notify.watchWait == nil)

        let wait = try ToasttyCLI.parse(arguments: ["task", "watch", taskID, "--until", "merged", "--wait", "--timeout", "30"], environment: [:])
        #expect(wait.command == .appControlRun(kind: .action, id: "task.watch", args: [
            "taskID": .string(taskID), "until": .string("merged"), "wait": .bool(true),
        ]))
        #expect(wait.watchWait == CLIWatchWait(timeout: 30))
        #expect(try ToasttyCLI.parse(arguments: ["task", "watch", taskID, "--until", "idle", "--wait"], environment: [:]).watchWait
            == CLIWatchWait(timeout: nil))

        #expect(try ToasttyCLI.parse(arguments: ["task", "list", "--changed-since", "ab12.7", "--include-reply"], environment: [:]).command
            == .appControlRun(kind: .query, id: "task.list", args: ["changedSince": .string("ab12.7"), "includeReply": .bool(true)]))
        let listWait = try ToasttyCLI.parse(
            arguments: ["task", "list", "--changed-since", "ab12.7", "--wait", "--until", "created", "--timeout", "60"],
            environment: [:]
        )
        #expect(listWait.command == .appControlRun(kind: .query, id: "task.list", args: ["changedSince": .string("ab12.7")]))
        #expect(listWait.listWait == CLIListWait(timeout: 60))
        for arguments in [
            ["task", "list", "--wait", "--until", "created"],
            ["task", "list", "--changed-since", "ab12.7", "--wait"],
            ["task", "list", "--changed-since", "ab12.7", "--wait", "--until", "idle"],
            ["task", "list", "--changed-since", "ab12.7", "--until", "created"],
        ] {
            #expect(throws: ToasttyCLIError.self) { try ToasttyCLI.parse(arguments: arguments, environment: [:]) }
        }
        #expect(try ToasttyCLI.parse(arguments: ["task", "watches", "--notify", other], environment: [:]).command
            == .appControlRun(kind: .query, id: "task.watches", args: ["notifyTaskID": .string(other)]))
        #expect(try ToasttyCLI.parse(arguments: ["task", "get"], environment: [:]).command
            == .appControlRun(kind: .query, id: "task.get", args: [:]))
        #expect(try ToasttyCLI.parse(arguments: ["task", "unwatch", other], environment: [:]).command
            == .appControlRun(kind: .action, id: "task.unwatch", args: ["watchID": .string(other)]))
    }

    @Test
    func packetCommandsSendThePacketTextAndAbsoluteScreenshotPaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-cli-packet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let packet = #"{"summary": "s", "look_at": "l", "not_verified": []}"#
        try packet.write(to: directory.appendingPathComponent("packet.json"), atomically: true, encoding: .utf8)
        let taskID = UUID().uuidString
        func command(_ arguments: [String]) throws -> CLICommand {
            try ToasttyCLI.parse(arguments: ["task", "packet"] + arguments, environment: ["PWD": directory.path]).command
        }

        // A task's agent publishes for its own task.
        #expect(try command(["publish", "--file", "packet.json", "--screenshot", "after-390.png", "--screenshot", "/abs/before-390.png"])
            == .appControlRun(kind: .action, id: "task.packet.publish", args: [
                "packet": .string(packet),
                "screenshots": .array([.string(directory.appendingPathComponent("after-390.png").path), .string("/abs/before-390.png")]),
            ]))
        #expect(try command(["publish", taskID, "--file", directory.appendingPathComponent("packet.json").path])
            == .appControlRun(kind: .action, id: "task.packet.publish", args: ["taskID": .string(taskID), "packet": .string(packet)]))
        #expect(try command(["get"]) == .appControlRun(kind: .action, id: "task.packet.get", args: [:]))
        #expect(try command(["get", taskID, "--version", "2"])
            == .appControlRun(kind: .action, id: "task.packet.get", args: ["taskID": .string(taskID), "version": .int(2)]))

        for (arguments, message) in [
            (["publish"], "task packet publish requires --file <packet.json>"),
            (["publish", "not-a-task", "--file", "packet.json"], "task packet publish takes a task ID"),
            (["get", "--version", "0"], "--version must be a packet version from 1"),
            (["show"], "unknown task packet subcommand: show"),
            ([], "task packet requires publish or get"),
        ] {
            do {
                _ = try command(arguments)
                Issue.record("expected a usage error for \(arguments)")
            } catch ToasttyCLIError.usage(let text) {
                #expect(text.hasPrefix(message), "\(arguments)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
        #expect(throws: ToasttyCLIError.self) { try command(["publish", "--file", "missing.json"]) }
    }

    @Test
    func lifecycleVerbsMapToTheirActions() throws {
        let taskID = UUID().uuidString
        let workspaceID = UUID().uuidString
        func command(_ arguments: [String]) throws -> CLICommand {
            try ToasttyCLI.parse(arguments: ["task"] + arguments, environment: [:]).command
        }

        // A task's agent merges its own task; a coordinator names a child.
        #expect(try command(["merge", "--head", "abc1234"])
            == .appControlRun(kind: .action, id: "task.merge", args: ["head": .string("abc1234")]))
        #expect(try command(["merge", taskID])
            == .appControlRun(kind: .action, id: "task.merge", args: ["taskID": .string(taskID)]))
        #expect(try command(["cancel-merge"]) == .appControlRun(kind: .action, id: "task.cancel-merge", args: [:]))
        #expect(try command(["ready-for-review"]) == .appControlRun(kind: .action, id: "task.ready-for-review", args: [:]))
        #expect(try command(["mark-done", taskID])
            == .appControlRun(kind: .action, id: "task.mark-done", args: ["taskID": .string(taskID)]))
        #expect(try command(["clean-up", taskID])
            == .appControlRun(kind: .action, id: "task.clean-up", args: ["taskID": .string(taskID)]))
        #expect(try command(["archive", taskID, "--close-pr", "--discard-changes"])
            == .appControlRun(kind: .action, id: "task.archive", args: [
                "taskID": .string(taskID),
                "closePullRequest": .bool(true),
                "deleteUnpushedCommits": .bool(false),
                "discardChanges": .bool(true),
            ]))
        #expect(try command(["release"]) == .appControlRun(kind: .action, id: "task.release", args: [:]))
        #expect(try command(["release", "--workspace", workspaceID])
            == .appControlRun(kind: .action, id: "task.release", args: ["workspaceID": .string(workspaceID)]))
        #expect(try command(["list", "--parent", taskID])
            == .appControlRun(kind: .query, id: "task.list", args: ["parent": .string(taskID)]))

        for arguments in [
            ["mark-done"], ["clean-up"], ["archive"], ["archive", "not-an-id"], ["merge", "a", "b"],
            ["merge", "--head"], ["release", "extra"], ["list", "--parent", "nope"],
        ] {
            #expect(throws: ToasttyCLIError.self, "\(arguments)") { try command(arguments) }
        }
    }

    @Test
    func sendAndWatchRejectAmbiguousArguments() {
        let taskID = UUID().uuidString
        for arguments in [
            ["task", "send", taskID],
            ["task", "send", taskID, "one", "--text", "two"],
            ["task", "send", "not-an-id", "hi"],
            ["task", "watch", taskID],
            ["task", "watch", taskID, "--until", "idle", "--notify", taskID, "--wait"],
            ["task", "watch", taskID, "--until", "idle", "--timeout", "5"],
            ["task", "watches", "--task", "nope"],
        ] {
            #expect(throws: ToasttyCLIError.self, "\(arguments)") {
                _ = try ToasttyCLI.parse(arguments: arguments, environment: [:])
            }
        }
    }

    @Test
    func coordinatorCommandsMapToTheirActions() throws {
        func command(_ arguments: [String]) throws -> CLICommand {
            try ToasttyCLI.parse(arguments: ["coordinator"] + arguments, environment: [:]).command
        }
        let taskID = UUID().uuidString
        #expect(try command(["post", "packet", "--task", taskID])
            == .appControlRun(kind: .action, id: "coordinator.post", args: ["kind": .string("packet"), "taskID": .string(taskID)]))
        #expect(try command(["post", "question", "Which base?", "--task", taskID])
            == .appControlRun(kind: .action, id: "coordinator.post", args: [
                "kind": .string("question"),
                "taskID": .string(taskID),
                "text": .string("Which base?"),
            ]))
        #expect(try command(["post", "question", "Which base?", "--option", "Remote main", "--task", taskID, "--option", "Feature branch"])
            == .appControlRun(kind: .action, id: "coordinator.post", args: [
                "kind": .string("question"),
                "taskID": .string(taskID),
                "text": .string("Which base?"),
                "options": .array([.string("Remote main"), .string("Feature branch")]),
            ]))
        #expect(try command(["post", "note", "--text", "Fresh session."])
            == .appControlRun(kind: .action, id: "coordinator.post", args: ["kind": .string("note"), "text": .string("Fresh session.")]))
        #expect(try command(["status"]) == .appControlRun(kind: .query, id: "coordinator.status", args: [:]))
        #expect(try command(["show-terminal"]) == .appControlRun(kind: .action, id: "coordinator.show-terminal", args: [:]))
        #expect(try command(["tasks"]) == .appControlRun(kind: .action, id: "coordinator.tasks.show", args: [:]))
        #expect(try command(["show"]) == .appControlRun(kind: .action, id: "coordinator.chat.show", args: [:]))
        let shownTask = UUID().uuidString
        #expect(try command(["show", "--task", shownTask])
            == .appControlRun(kind: .action, id: "coordinator.chat.show", args: ["taskID": .string(shownTask)]))
        #expect(throws: ToasttyCLIError.self) { try command(["show", "--task", "nope"]) }
        #expect(throws: ToasttyCLIError.self) { try command(["show", "extra"]) }

        for arguments in [["post"], ["post", "note", "a", "b"], ["post", "note", "a", "--text", "b"], ["post", "packet", "--task", "abc"], ["post", "question", "--option"], ["status", "x"], ["open"]] {
            #expect(throws: ToasttyCLIError.self, "\(arguments)") { try command(arguments) }
        }
    }
}
