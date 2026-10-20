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
        ["task", "get"],
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
}
